### Proximal gradient method
export ProxGradParams, fit!

type ProxGradParams<:AbstractParams
    stepsize::Float64 # initial stepsize
    max_iter::Int # maximum number of outer iterations
    inner_iter::Int # how many prox grad steps to take on X before moving on to Y (and vice versa)
    convergence_tol::Float64 # stop if objective decrease upon one outer iteration is less than this
    min_stepsize::Float64 # use a decreasing stepsize, stop when reaches min_stepsize
end
function ProxGradParams(stepsize::Number=1.0; # initial stepsize
				        max_iter::Int=100, # maximum number of outer iterations
				        inner_iter::Int=1, # how many prox grad steps to take on X before moving on to Y (and vice versa)
				        convergence_tol::Number=0.00001, # stop if objective decrease upon one outer iteration is less than this
				        min_stepsize::Number=0.01*stepsize) # stop if stepsize gets this small
    stepsize = convert(Float64, stepsize)
    return ProxGradParams(convert(Float64, stepsize), 
                          max_iter, 
                          inner_iter, 
                          convert(Float64, convergence_tol), 
                          convert(Float64, min_stepsize))
end

### FITTING
function fit!(glrm::GLRM, params::ProxGradParams;
			  ch::ConvergenceHistory=ConvergenceHistory("ProxGradGLRM"), 
			  verbose=true,
			  kwargs...)
	### initialization
	A = glrm.A # rename these for easier local access
	losses = glrm.losses
	rx = glrm.rx
	ry = glrm.ry
	# at any time, glrm.X and glrm.Y will be the best model yet found, while
	# X and Y will be the working variables
	X = copy(glrm.X); Y = copy(glrm.Y)
	k = glrm.k
    m,n = size(A)

    # find spans of loss functions (for multidimensional losses)
    yidxs = get_yidxs(losses)
    d = maximum(yidxs[end])
    # check Y is the right size
    if d != size(Y,2)
        warn("The width of Y should match the embedding dimension of the losses.
            Instead, embedding_dim(glrm.losses) = $(embedding_dim(glrm.losses))
            and size(glrm.Y, 2) = $(size(glrm.Y, 2)). 
            Reinitializing Y as randn(glrm.k, embedding_dim(glrm.losses).")
            # Please modify Y or the embedding dimension of the losses to match,
            # eg, by setting `glrm.Y = randn(glrm.k, embedding_dim(glrm.losses))`")
        glrm.Y = randn(glrm.k, embedding_dim(glrm.losses))
    end

    XY = Array(Float64, (m, d))
    gemm!('T','N',1.0,X,Y,0.0,XY) # XY = X' * Y initial calculation

    # check that we didn't initialize to zero (otherwise we will never move)
    if norm(Y) == 0 
    	Y = .1*randn(k,n) 
    end

    # step size (will be scaled below to ensure it never exceeds 1/\|g\|_2 or so for any subproblem)
    alpha = params.stepsize
    # stopping criterion: stop when decrease in objective < tol
    tol = params.convergence_tol * mapreduce(length,+,glrm.observed_features)

    # alternating updates of X and Y
    if verbose println("Fitting GLRM") end
    update!(ch, 0, objective(glrm, X, Y, XY, yidxs=yidxs))
    t = time()
    steps_in_a_row = 0
    # gradient wrt columns of X
    g = zeros(k)
    # gradient wrt column-chunks of Y
    G = zeros(k, d)

    # cache views
    # first a type hack
    @compat typealias Yview Union{ContiguousView{Float64,1,Array{Float64,2}}, 
                                  ContiguousView{Float64,2,Array{Float64,2}}}
    # views of the columns of X corresponding to each example
    ve = ContiguousView{Float64,1,Array{Float64,2}}[view(X,:,e) for e=1:m]
    # views of the column-chunks of Y corresponding to each feature
    vf = Yview[view(Y,:,yidxs[f]) for f=1:n]
    # views of the column-chunks of G corresponding to the gradient wrt each feature
    gf = Yview[view(G,:,yidxs[f]) for f=1:n]

    for i=1:params.max_iter
# STEP 1: X update
        # XY = X' * Y this is computed before the first iteration and subsequently in the objective evaluation
        for inneri=1:params.inner_iter
        for e=1:m # doing this means looping over XY in row-major order, but otherwise we couldn't parallelize over Xᵢs
            scale!(g, 0)# reset gradient to 0
            # compute gradient of L with respect to Xᵢ as follows:
            # ∇{Xᵢ}L = Σⱼ dLⱼ(XᵢYⱼ)/dXᵢ
            for f in glrm.observed_features[e]
                # but we have no function dLⱼ/dXᵢ, only dLⱼ/d(XᵢYⱼ) aka dLⱼ/du
                # by chain rule, the result is: Σⱼ (dLⱼ(XᵢYⱼ)/du * Yⱼ), where dLⱼ/du is our grad() function
                curgrad = grad(losses[f],XY[e,yidxs[f]],A[e,f])
                if isa(curgrad, Number)
                    axpy!(curgrad, vf[f], g)
                else
                    gemm!('N', 'T', 1.0, vf[f], curgrad, 1.0, g)
                end
            end
            # take a proximal gradient step
            l = length(glrm.observed_features[e]) + 1
            ## gradient step: Xᵢ += -(α/l) * ∇{Xᵢ}L
            axpy!(-alpha/l,g,ve[e])
            ## prox step: Xᵢ = prox_rx(Xᵢ, α/l)
            prox!(rx,ve[e],alpha/l)
        end
        end
        gemm!('T','N',1.0,X,Y,0.0,XY) # Recalculate XY using the new X
# STEP 2: Y update
        for inneri=1:params.inner_iter
        scale!(G, 0)
        for f=1:n
            # compute gradient of L with respect to Yⱼ as follows:
            # ∇{Yⱼ}L = Σⱼ dLⱼ(XᵢYⱼ)/dYⱼ 
            for e in glrm.observed_examples[f]
                # but we have no function dLⱼ/dYⱼ, only dLⱼ/d(XᵢYⱼ) aka dLⱼ/du
                # by chain rule, the result is: Σⱼ dLⱼ(XᵢYⱼ)/du * Xᵢ, where dLⱼ/du is our grad() function
                curgrad = grad(losses[f],XY[e,yidxs[f]],A[e,f])
                if isa(curgrad, Number)
                    axpy!(curgrad, ve[e], gf[f])
                else
                    gemm!('N', 'N', 1.0, ve[e], curgrad, 1.0, gf[f])
                end
            end
            # take a proximal gradient step
            l = length(glrm.observed_examples[f]) + 1
            ## gradient step: Yⱼ += -(α/l) * ∇{Yⱼ}L
            axpy!(-alpha/l,gf[f],vf[f]) 
            ## prox step: Yⱼ = prox_ryⱼ(Yⱼ, α/l)
            prox!(ry[f],vf[f],alpha/l)
        end
        end
        gemm!('T','N',1.0,X,Y,0.0,XY) # Recalculate XY using the new Y
# STEP 3: Check objective
        obj = objective(glrm, X, Y, XY, yidxs=yidxs) 
        # record the best X and Y yet found
        if obj < ch.objective[end]
            t = time() - t
            update!(ch, t, obj)
            copy!(glrm.X, X); copy!(glrm.Y, Y)
            alpha = alpha * 1.05
            steps_in_a_row = max(1, steps_in_a_row+1)
            t = time()
        else
            # if the objective went up, reduce the step size, and undo the step
            alpha = alpha / max(1.5, -steps_in_a_row)
            if verbose println("obj went up to $obj; reducing step size to $alpha") end
            copy!(X, glrm.X); copy!(Y, glrm.Y)
            steps_in_a_row = min(0, steps_in_a_row-1)
            gemm!('T','N',1.0,X,Y,0.0,XY) # Revert back to the old XY (previous best)
        end
# STEP 4: Check stopping criterion
        if i>10 && (steps_in_a_row > 3 && ch.objective[end-1] - obj < tol) || alpha <= params.min_stepsize
            break
        end
        if verbose && i%10==0 
            println("Iteration $i: objective value = $(ch.objective[end])") 
        end
    end
    t = time() - t
    update!(ch, t, ch.objective[end])

    return glrm.X, glrm.Y, ch
end
