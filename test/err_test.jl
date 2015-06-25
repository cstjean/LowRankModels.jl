using LowRankModels
using Plotly
srand(1);

test_losses = Loss[
quadratic(), 	
#l1(), 			
#huber(), 		
periodic(1), 	
ordinal_hinge(1,10),
logistic(), 		
weighted_hinge()
]

#for test_iteration = 1:10
	# Create the configuration for the model (random losses)
	config = int(abs(round(10*rand(length(test_losses)))));
	config = [0 0 1 0 10 0 100]
	losses, doms = Array(Loss,1), Array(Domain,1);
	for (n,l) in zip(config, test_losses)
		for i=1:n
			push!(losses, l);
			push!(doms, l.domain);
		end
	end
	losses, doms = losses[2:end], doms[2:end]; # this is because the initialization leaves us with an #undef
	
	# Make a low rank matrix as our data precursor
	m, n, true_k = 1000, length(doms), int(round(length(losses)/2)); 
	X_real, Y_real = 2*randn(m,true_k), 2*randn(true_k,n);
	A_real = X_real*Y_real;

	# Impute over the low rank-precursor to make our heterogenous dataset
	A = impute(doms, losses, A_real);				# our data with noise

	# Create a glrm using these losses and data
	p = Params(1, max_iter=10000, convergence_tol=0.00000001, min_stepsize=0.0000001)
	model_k = true_k;
	rx, ry = zeroreg(), zeroreg();
	hetero = GLRM(A, losses, rx,ry,model_k, scale=false, offset=false);

	# Test that our imputation is consistent
	if !(error_metric(hetero, doms, X_real', Y_real) == 0)
		error("Imputation failed.")
	end

	real_obj = objective(hetero, X_real', Y_real, include_regularization=false);

	X_fit,Y_fit,ch = fit!(hetero, params=p, verbose=false);

	println("model objective: $(ch.objective[end])")
	println("objective using data precursor: $real_obj")
	err = error_metric(hetero, doms, X_fit, Y_fit)
	if err != 0
		println("Model did not correctly impute all entries. Average error: $(err/(m*n))")
	end
	data = [
		[
			"z" => errors(doms, losses, X_fit'*Y_fit, A)',
			"x" => [string(typeof(l),"    ",randn()) for l in losses],
			"type" => "heatmap"
		]
	]
	response = Plotly.plot(data, ["filename" => "labelled-heatmap", "fileopt" => "overwrite"])
	plot_url = response["url"]
	# println(final_obj/initial_obj)
	# println(real_obj/initial_obj)
#end