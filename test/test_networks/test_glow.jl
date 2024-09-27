# Generative model w/ Glow architecture from Kingma & Dhariwal (2018)
# Author: Philipp Witte, pwitte3@gatech.edu
# Date: January 2020

using InvertibleNetworks, LinearAlgebra, Test, Flux, Random
device = InvertibleNetworks.CUDA.functional() ? gpu : cpu
(device == gpu) && println("Testing on GPU"); 

mean(x) = sum(x)/length(x)

hfactor=8f-1
expected_f1 = 1f0 / hfactor
expected_f2 = 1f0 / hfactor ^2f0


# Random seed
m = MersenneTwister()

# Define network
nx = 29
ny = 31
nz = 37
n_in = 3
n_hidden = 4
batchsize = 2
L = 2
K = 2

for logdet_bool = [true,false] #logdet is not tested in Jacobian yet. 
    for split_scales = [true,false]
        for N in [(nx, ny), (nx, ny, nz)]
            println("Testing Glow with dimensions=$(N) logdet=$(logdet_bool) and split_scales=$(split_scales)")
            
            # Network and input
            G = NetworkGlow(n_in, n_hidden, L, K;logdet=logdet_bool, split_scales=split_scales, ndims=length(N))|> device
            X = rand(m,Float32, N..., n_in, batchsize)|> device

            # Invertibility
            if logdet_bool
                Y, _ = G.forward(X)
            else 
                Y = G.forward(X)
            end
            X_ = G.inverse(Y)

            @test isapprox(norm(X - X_)/norm(X), 0f0; atol=1f-5)

            ###################################################################################################
            # Test gradients are set and cleared
            G.backward(Y, Y)

            P = get_params(G)
            gsum = 0
            for p in P
                ~isnothing(p.grad) && (gsum += 1)
            end
            
            param_factor = 10
            @test isequal(gsum, L*K*param_factor)

            clear_grad!(G)
            gsum = 0
            for p in P
                ~isnothing(p.grad) && (gsum += 1)
            end
            @test isequal(gsum, 0)


            ###################################################################################################
            # Gradient test

            
            function loss(G, X)
                if G.logdet 
                    Y, logdet = G.forward(X)
                    f = -log_likelihood(Y) - logdet
                else
                    Y = G.forward(X)
                    f = -log_likelihood(Y) 
                end  
                ΔY = -∇log_likelihood(Y)
                ΔX, X_ = G.backward(ΔY, Y)
                return f, ΔX, G.CL[1,1].RB.W1.grad, G.CL[1,1].C.v1.grad
            end

            # Gradient test w.r.t. input
            G = NetworkGlow(n_in, n_hidden, L, K;logdet=logdet_bool, split_scales=split_scales, ndims=length(N))|> device
            X = rand(m,Float32, N..., n_in, batchsize)|> device
            X0 = rand(m,Float32, N..., n_in, batchsize)|> device
            dX = X - X0

            f0, ΔX = loss(G, X0)[1:2]
            h = 0.1f0
            maxiter = 4
            err1 = zeros(Float32, maxiter)
            err2 = zeros(Float32, maxiter)

            print("\nGradient test glow: input\n")
            for j=1:maxiter
                f = loss(G, X0 + h*dX,)[1]
                err1[j] = abs(f - f0)
                err2[j] = abs(f - f0 - h*dot(dX, ΔX))
                print(err1[j], "; ", err2[j], "\n")
                h = h/2f0
            end

            @test isapprox(err1[end] / (err1[1]/2^(maxiter-1)), 1f0; atol=1f1)
            @test isapprox(err2[end] / (err2[1]/4^(maxiter-1)), 1f0; atol=1f1)

            num_attempts = 3
            results_1 = []
            results_2 = []
            for i in 1:num_attempts
                Random.seed!(i)

                # Gradient test w.r.t. parameters
                X = rand(m,Float32, N..., n_in, batchsize)|> device
                G = NetworkGlow(n_in, n_hidden, L, K; logdet=logdet_bool, split_scales=split_scales, ndims=length(N))|> device
                G0 = NetworkGlow(n_in, n_hidden, L, K;logdet=logdet_bool, split_scales=split_scales, ndims=length(N))|> device
                Gini = deepcopy(G0)

                # Test one parameter from residual block and 1x1 conv
                dW = G.CL[1,1].RB.W1.data - G0.CL[1,1].RB.W1.data
                dv = G.CL[1,1].C.v1.data - G0.CL[1,1].C.v1.data

                f0, ΔX, ΔW, Δv = loss(G0, X)
                h = 0.1f0
                maxiter = 4
                err3 = zeros(Float32, maxiter)
                err4 = zeros(Float32, maxiter)

                print("\nGradient test glow: input\n")
                for j=1:maxiter
                    G0.CL[1,1].RB.W1.data = Gini.CL[1,1].RB.W1.data + h*dW
                    G0.CL[1,1].C.v1.data = Gini.CL[1,1].C.v1.data + h*dv

                    f = loss(G0, X)[1]
                    err3[j] = abs(f - f0)
                    err4[j] = abs(f - f0 - h*dot(dW, ΔW) - h*dot(dv, Δv))
                    print(err3[j], "; ", err4[j], "\n")
                    h = h*hfactor
                end

                factor1 = err3[1:end-1]./err3[2:end]
                factor2 = err4[1:end-1]./err4[2:end]

                append!(results_1,isapprox(mean(factor1), expected_f1; atol=1f0))
                append!(results_2,isapprox(mean(factor2), expected_f2; atol=1f0))
            end
            @test true in results_1
            @test true in results_2

            ###################################################################################################
            # Jacobian-related tests 

            # Gradient test

            # Initialization
            G = NetworkGlow(n_in, n_hidden, L, K; ndims=length(N))|> device; G.forward(randn(Float32, N..., n_in, batchsize)|> device)
            θ = deepcopy(get_params(G))
            G0 = NetworkGlow(n_in, n_hidden, L, K; ndims=length(N))|> device; G0.forward(randn(Float32, N..., n_in, batchsize)|> device)
            θ0 = deepcopy(get_params(G0))
            X = randn(Float32, N..., n_in, batchsize)|> device

            # Perturbation (normalized)
            dθ = θ-θ0
            dθ .*= norm.(θ0)./(norm.(dθ).+1f-10)
            dX = randn(Float32, N..., n_in, batchsize)|> device; dX *= norm(X)/norm(dX)


            # Jacobian eval
            dY, Y, _, _ = G.jacobian(dX|> device, dθ|> device, X)

            # Test
            print("\nJacobian test\n")
            h = 0.1f0
            maxiter = 5
            err5 = zeros(Float32, maxiter)
            err6 = zeros(Float32, maxiter)
            for j=1:maxiter
                set_params!(G, θ+h*dθ)
                Y_loc, _ = G.forward(X+h*dX)
                err5[j] = norm(Y_loc - Y)
                err6[j] = norm(Y_loc - Y - h*dY)
                print(err5[j], "; ", err6[j], "\n")
                h = h/2f0
            end

            @test isapprox(err5[end] / (err5[1]/2^(maxiter-1)), 1f0; atol=1f1)
            @test isapprox(err6[end] / (err6[1]/4^(maxiter-1)), 1f0; atol=1f1)

            # Adjoint test

            set_params!(G, θ)
            dY, Y, _, _ = G.jacobian(dX, dθ, X)
            dY_ = randn(Float32, size(dY))|> device
            dX_, dθ_, _, _ = G.adjointJacobian(dY_, Y)
            a = dot(dY, dY_)
            b = dot(dX, dX_) + dot(dθ, dθ_)
            @test isapprox(a, b; rtol=1f-2)
        end
    end
end
