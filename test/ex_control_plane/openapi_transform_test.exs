defmodule ExControlPlane.OpenapiTransformTest do
  use ExUnit.Case, async: true

  alias ExControlPlane.OpenapiTransform

  import ExControlPlane.TestHelpers

  describe "transform/4" do
    test "transforms simple GET endpoint" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" => operation()
            }
          }
        )

      {routes, clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      assert length(routes) == 1
      [route] = routes

      assert route["name"] == "test-api-get-/users"
      assert route["match"]["path"] == "/api/users"

      # Check HTTP method header match
      headers = route["match"]["headers"]
      method_header = Enum.find(headers, &(&1["name"] == ":method"))
      assert method_header["string_match"]["exact"] == "GET"

      # Check cluster configuration
      assert route["route"]["cluster"] == "https://api.example.com:443"
      assert route["route"]["auto_host_rewrite"] == true

      # Check clusters returned
      assert length(clusters) == 1
      {cluster_name, cluster_uri} = hd(clusters)
      assert cluster_name == "https://api.example.com:443"
      assert cluster_uri.host == "api.example.com"
      assert cluster_uri.port == 443
    end

    test "transforms multiple HTTP methods on same path" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" => operation(),
              "post" => operation(),
              "put" => operation(),
              "delete" => operation()
            }
          }
        )

      {routes, clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      assert length(routes) == 4

      methods =
        Enum.map(routes, fn route ->
          headers = route["match"]["headers"]
          method_header = Enum.find(headers, &(&1["name"] == ":method"))
          method_header["string_match"]["exact"]
        end)

      assert Enum.sort(methods) == ["DELETE", "GET", "POST", "PUT"]

      # All routes should use the same cluster
      assert length(clusters) == 1
    end

    test "transforms path with single template variable" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users/{id}" => %{
              "get" => operation()
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes

      # Should use path_match_policy for template variables
      assert route["match"]["path_match_policy"]["name"] ==
               "envoy.path.match.uri_template.uri_template_matcher"

      typed_config = route["match"]["path_match_policy"]["typed_config"]

      assert typed_config["@type"] ==
               "type.googleapis.com/envoy.extensions.path.match.uri_template.v3.UriTemplateMatchConfig"

      # {id} should be converted to {var0}
      assert typed_config["path_template"] == "/api/users/{var0}"

      # Should have path_rewrite_policy for server path
      assert route["route"]["path_rewrite_policy"]["name"] ==
               "envoy.path.rewrite.uri_template.uri_template_rewriter"

      rewrite_config = route["route"]["path_rewrite_policy"]["typed_config"]
      assert rewrite_config["path_template_rewrite"] == "/users/{var0}"
    end

    test "transforms path with wildcard requestPath variable" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/{requestPath}" => %{
              "get" => operation()
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes

      typed_config = route["match"]["path_match_policy"]["typed_config"]
      # requestPath should use ** wildcard
      assert typed_config["path_template"] == "/api/{requestPath=**}"

      rewrite_config = route["route"]["path_rewrite_policy"]["typed_config"]
      assert rewrite_config["path_template_rewrite"] == "/{requestPath}"
    end

    test "transforms path with multiple template variables" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users/{userId}/posts/{postId}" => %{
              "get" => operation()
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes

      typed_config = route["match"]["path_match_policy"]["typed_config"]
      assert typed_config["path_template"] == "/api/users/{var0}/posts/{var1}"

      rewrite_config = route["route"]["path_rewrite_policy"]["typed_config"]
      assert rewrite_config["path_template_rewrite"] == "/users/{var0}/posts/{var1}"
    end

    test "transforms weighted clusters with multiple servers" do
      spec =
        minimal_openapi_spec(
          servers: [
            %{"url" => "https://primary.example.com:443", "x-proxyconf-server-weight" => 80},
            %{"url" => "https://secondary.example.com:443", "x-proxyconf-server-weight" => 20}
          ],
          paths: %{
            "/users" => %{
              "get" => operation()
            }
          }
        )

      {routes, clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes

      # Should have weighted_clusters instead of single cluster
      assert is_map(route["route"]["weighted_clusters"])
      weighted_clusters = route["route"]["weighted_clusters"]["clusters"]

      assert length(weighted_clusters) == 2

      primary = Enum.find(weighted_clusters, &(&1["name"] =~ "primary"))
      secondary = Enum.find(weighted_clusters, &(&1["name"] =~ "secondary"))

      assert primary["weight"] == 80
      assert secondary["weight"] == 20

      # Both clusters should be returned
      assert length(clusters) == 2
    end

    test "assigns default weights to servers without explicit weight" do
      spec =
        minimal_openapi_spec(
          servers: [
            %{"url" => "https://primary.example.com:443", "x-proxyconf-server-weight" => 100},
            %{"url" => "https://secondary.example.com:443"}
          ],
          paths: %{
            "/users" => %{
              "get" => operation()
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      weighted_clusters = route["route"]["weighted_clusters"]["clusters"]

      secondary = Enum.find(weighted_clusters, &(&1["name"] =~ "secondary"))
      # Weight should be min_weight - 1 = 99
      assert secondary["weight"] == 99
    end

    test "transforms websocket-enabled endpoint" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/ws" => %{
              "get" => Map.put(operation(), "x-proxyconf-websocket", "enabled")
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes

      # Should have websocket upgrade config enabled
      upgrade_configs = route["route"]["upgrade_configs"]
      assert length(upgrade_configs) == 1

      ws_config = hd(upgrade_configs)
      assert ws_config["upgrade_type"] == "websocket"
      assert ws_config["enabled"] == true

      # Should have upgrade header match
      headers = route["match"]["headers"]
      upgrade_header = Enum.find(headers, &(&1["name"] == "upgrade"))
      assert upgrade_header["present_match"] == true
    end

    test "transforms endpoint with required header parameters" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" =>
                operation(
                  parameters: [
                    %{"name" => "X-Api-Key", "in" => "header", "required" => true},
                    %{"name" => "X-Request-Id", "in" => "header", "required" => true},
                    %{"name" => "X-Optional", "in" => "header", "required" => false}
                  ]
                )
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      # Should have present_match for required headers
      api_key_header = Enum.find(headers, &(&1["name"] == "X-Api-Key"))
      assert api_key_header["present_match"] == true

      request_id_header = Enum.find(headers, &(&1["name"] == "X-Request-Id"))
      assert request_id_header["present_match"] == true

      # Optional header should not be present
      optional_header = Enum.find(headers, &(&1["name"] == "X-Optional"))
      assert is_nil(optional_header)
    end

    test "transforms endpoint with required query parameters" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" =>
                operation(
                  parameters: [
                    %{"name" => "page", "in" => "query", "required" => true},
                    %{"name" => "limit", "in" => "query", "required" => true},
                    %{"name" => "filter", "in" => "query", "required" => false}
                  ]
                )
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      query_params = route["match"]["query_parameters"]

      assert length(query_params) == 2

      page_param = Enum.find(query_params, &(&1["name"] == "page"))
      assert page_param["present_match"] == true

      limit_param = Enum.find(query_params, &(&1["name"] == "limit"))
      assert limit_param["present_match"] == true
    end

    test "transforms endpoint with request body media type validation" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "post" =>
                operation(
                  request_body: %{
                    "required" => true,
                    "content" => %{
                      "application/json" => %{},
                      "application/xml" => %{}
                    }
                  }
                )
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      content_type_header = Enum.find(headers, &(&1["name"] == "content-type"))
      assert content_type_header != nil

      regex = content_type_header["string_match"]["safe_regex"]["regex"]
      # Should match application/json or application/xml
      assert regex =~ "application\\/json"
      assert regex =~ "application\\/xml"
      # Required request body should not allow empty
      refute regex =~ "^$"
    end

    test "transforms endpoint with optional request body allowing empty content-type" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "post" =>
                operation(
                  request_body: %{
                    "required" => false,
                    "content" => %{
                      "application/json" => %{}
                    }
                  }
                )
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      content_type_header = Enum.find(headers, &(&1["name"] == "content-type"))
      assert content_type_header != nil
      assert content_type_header["treat_missing_header_as_empty"] == true

      regex = content_type_header["string_match"]["safe_regex"]["regex"]
      # Optional request body should allow empty
      assert regex =~ "^$"
    end

    test "transforms endpoint with wildcard media type" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/upload" => %{
              "post" =>
                operation(
                  request_body: %{
                    "required" => true,
                    "content" => %{
                      "image/*" => %{}
                    }
                  }
                )
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      content_type_header = Enum.find(headers, &(&1["name"] == "content-type"))
      regex = content_type_header["string_match"]["safe_regex"]["regex"]
      # Wildcard should be converted to regex pattern
      assert regex =~ "image\\/[a-zA-Z0-9_-]+"
    end

    test "transforms server with variable substitution" do
      spec =
        minimal_openapi_spec(
          servers: [
            %{
              "url" => "{protocol}://{hostname}:{port}",
              "variables" => %{
                "protocol" => %{"default" => "https"},
                "hostname" => %{"default" => "api.example.com"},
                "port" => %{"default" => "443"}
              }
            }
          ],
          paths: %{
            "/users" => %{
              "get" => operation()
            }
          }
        )

      {routes, clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      assert route["route"]["cluster"] == "https://api.example.com:443"

      [{cluster_name, cluster_uri}] = clusters
      assert cluster_name == "https://api.example.com:443"
      assert cluster_uri.host == "api.example.com"
      assert cluster_uri.port == 443
      assert cluster_uri.scheme == "https"
    end

    test "transforms endpoint with parameter $ref resolution for location grouping" do
      # Note: Current implementation resolves $ref for location grouping but doesn't
      # fully dereference the parameter for required checks. This test verifies
      # that the route is created successfully with $ref parameters.
      spec = %{
        "openapi" => "3.0.3",
        "info" => %{"title" => "Test", "version" => "1.0.0"},
        "servers" => [%{"url" => "https://api.example.com:443"}],
        "components" => %{
          "parameters" => %{
            "ApiKeyHeader" => %{
              "name" => "X-Api-Key",
              "in" => "header",
              "required" => true
            }
          }
        },
        "paths" => %{
          "/users" => %{
            "get" => %{
              "parameters" => [
                %{"$ref" => "#/components/parameters/ApiKeyHeader"}
              ],
              "responses" => %{"200" => %{"description" => "OK"}}
            }
          }
        }
      }

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      # Verify that the route is created successfully even with $ref parameters
      [route] = routes
      assert route["name"] == "test-api-get-/users"
      assert route["match"]["path"] == "/api/users"
    end

    test "respects fail-fast-on-missing-query-parameter option when disabled" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" =>
                operation(
                  parameters: [
                    %{"name" => "page", "in" => "query", "required" => true}
                  ]
                )
                |> Map.put("x-proxyconf-fail-fast-on-missing-query-parameter", false)
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      query_params = route["match"]["query_parameters"]

      # Should not have required query parameter matches when disabled
      assert query_params == []
    end

    test "respects fail-fast-on-missing-header-parameter option when disabled" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" =>
                operation(
                  parameters: [
                    %{"name" => "X-Api-Key", "in" => "header", "required" => true}
                  ]
                )
                |> Map.put("x-proxyconf-fail-fast-on-missing-header-parameter", false)
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      # Should only have :method header, not the required header
      assert length(headers) == 1
      assert hd(headers)["name"] == ":method"
    end

    test "respects fail-fast-on-wrong-request-media-type option when disabled" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "post" =>
                operation(
                  request_body: %{
                    "required" => true,
                    "content" => %{"application/json" => %{}}
                  }
                )
                |> Map.put("x-proxyconf-fail-fast-on-wrong-request-media-type", false)
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      # Should not have content-type header validation
      content_type_header = Enum.find(headers, &(&1["name"] == "content-type"))
      assert is_nil(content_type_header)
    end

    test "applies custom route_transform callback" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "get" => operation()
            }
          }
        )

      transform_fn = fn route ->
        Map.put(route, "custom_field", "custom_value")
      end

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec, transform_fn)

      [route] = routes
      assert route["custom_field"] == "custom_value"
    end

    test "inherits path-level parameters to operations" do
      spec =
        minimal_openapi_spec(
          paths: %{
            "/users" => %{
              "parameters" => [
                %{"name" => "X-Trace-Id", "in" => "header", "required" => true}
              ],
              "get" => operation(),
              "post" => operation()
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      assert length(routes) == 2

      # Both routes should have the inherited parameter
      Enum.each(routes, fn route ->
        headers = route["match"]["headers"]
        trace_header = Enum.find(headers, &(&1["name"] == "X-Trace-Id"))
        assert trace_header["present_match"] == true
      end)
    end

    test "operation-level servers override path-level servers" do
      spec =
        minimal_openapi_spec(
          servers: [%{"url" => "https://default.example.com:443"}],
          paths: %{
            "/users" => %{
              "get" => operation(servers: [%{"url" => "https://override.example.com:443"}])
            }
          }
        )

      {routes, clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      assert route["route"]["cluster"] == "https://override.example.com:443"

      [{cluster_name, _}] = clusters
      assert cluster_name == "https://override.example.com:443"
    end

    test "handles server with path prefix" do
      spec =
        minimal_openapi_spec(
          servers: [%{"url" => "https://api.example.com:443/v1"}],
          paths: %{
            "/users" => %{
              "get" => operation()
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      # prefix_rewrite should include server path
      assert route["route"]["prefix_rewrite"] == "/v1/users"
    end

    test "websocket endpoint enforces header parameter validation" do
      # Note: The implementation sets missing_header_param_check = websocket_enabled || ...
      # This means when websocket is enabled, header validation is always enforced
      spec =
        minimal_openapi_spec(
          paths: %{
            "/ws" => %{
              "get" =>
                operation(
                  parameters: [
                    %{"name" => "X-Api-Key", "in" => "header", "required" => true}
                  ]
                )
                |> Map.put("x-proxyconf-websocket", "enabled")
            }
          }
        )

      {routes, _clusters} = OpenapiTransform.transform("test-api", "/api", spec)

      [route] = routes
      headers = route["match"]["headers"]

      # Websocket endpoints still enforce required header validation
      api_key_header = Enum.find(headers, &(&1["name"] == "X-Api-Key"))
      assert api_key_header["present_match"] == true

      # And should have upgrade header for websocket
      upgrade_header = Enum.find(headers, &(&1["name"] == "upgrade"))
      assert upgrade_header["present_match"] == true
    end
  end

  describe "cluster_uri_from_oas3_server/1" do
    test "extracts cluster name and URI from valid server" do
      server = %{"url" => "https://api.example.com:8080"}

      {cluster_name, uri} = OpenapiTransform.cluster_uri_from_oas3_server(server)

      assert cluster_name == "https://api.example.com:8080"
      assert uri.scheme == "https"
      assert uri.host == "api.example.com"
      assert uri.port == 8080
    end

    test "applies server variables before parsing" do
      server = %{
        "url" => "{protocol}://{host}:{port}",
        "variables" => %{
          "protocol" => %{"default" => "https"},
          "host" => %{"default" => "api.example.com"},
          "port" => %{"default" => "443"}
        }
      }

      {cluster_name, uri} = OpenapiTransform.cluster_uri_from_oas3_server(server)

      assert cluster_name == "https://api.example.com:443"
      assert uri.host == "api.example.com"
    end

    test "raises for server URL without host" do
      server = %{"url" => "https://:8080"}

      assert_raise RuntimeError, ~r/invalid upstream server hostname/, fn ->
        OpenapiTransform.cluster_uri_from_oas3_server(server)
      end
    end

    test "raises for server URL without port (unknown scheme)" do
      # Note: Standard schemes like https/http get default ports (443/80)
      # This test uses an unknown scheme that doesn't have a default port
      server = %{"url" => "grpc://api.example.com"}

      assert_raise RuntimeError, ~r/invalid upstream server port/, fn ->
        OpenapiTransform.cluster_uri_from_oas3_server(server)
      end
    end
  end

  describe "route_name/3" do
    test "generates correct route name format" do
      name = OpenapiTransform.route_name("my-api", "get", "/users/{id}")

      assert name == "my-api-get-/users/{id}"
    end

    test "handles special characters in path" do
      name = OpenapiTransform.route_name("api", "post", "/users/{userId}/posts")

      assert name == "api-post-/users/{userId}/posts"
    end
  end
end
