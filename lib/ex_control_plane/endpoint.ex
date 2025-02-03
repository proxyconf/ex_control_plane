defmodule ExControlPlane.Endpoint do
  use GRPC.Endpoint
  intercept(GRPC.Server.Interceptors.Logger)
  run(ExControlPlane.AggregatedDiscoveryServiceServer)
end
