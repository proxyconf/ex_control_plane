defmodule ExControlPlane.OpenapiTransform do
  @operations Application.compile_env(
                :ex_control_plane,
                :transformed_methods,
                ~w/get put post delete options head patch trace/
              )

  def transform(
        api_id,
        "/" <> _ = path_prefix,
        %{"paths" => paths_object, "servers" => servers} = spec,
        route_transform \\ fn route -> route end
      ) do
    Enum.flat_map_reduce(paths_object, [], fn
      {path, path_item_object}, clusters_acc ->
        inherited_config =
          Map.merge(%{"servers" => servers}, path_item_object)
          |> Map.take(["parameters", "servers"])

        Enum.filter(path_item_object, fn {k, _} -> k in @operations end)
        |> Enum.map_reduce(clusters_acc, fn {operation, operation_object}, clusters_acc ->
          {route, clusters_acc} =
            operation_to_route_match(
              api_id,
              path_prefix,
              path,
              operation,
              DeepMerge.deep_merge(inherited_config, operation_object),
              clusters_acc,
              spec
            )

          {route_transform.(route), Enum.uniq(clusters_acc)}
        end)
    end)
  end

  @path_wildcard Application.compile_env(
                   :ex_control_plane,
                   :path_wildcard_variable,
                   "requestPath"
                 )
  @oas3_extension_prefix Application.compile_env(
                           :ex_control_plane,
                           :oas3_extension_prefix,
                           "x-proxyconf"
                         )
  @path_template_regex ~r/\{(.*?)\}/
  defp operation_to_route_match(
         api_id,
         path_prefix,
         path,
         operation,
         operation_object,
         clusters,
         spec
       ) do
    servers = Map.fetch!(operation_object, "servers")

    websocket_enabled =
      Map.get(operation_object, "#{@oas3_extension_prefix}-websocket") == "enabled"

    websocket =
      websocket_route(websocket_enabled)

    missing_query_param_check =
      Map.get(
        operation_object,
        "#{@oas3_extension_prefix}-fail-fast-on-missing-query-parameter",
        true
      )

    missing_header_param_check =
      websocket_enabled ||
        Map.get(
          operation_object,
          "#{@oas3_extension_prefix}-fail-fast-on-missing-header-parameter",
          true
        )

    wrong_request_media_type_check =
      Map.get(
        operation_object,
        "#{@oas3_extension_prefix}-fail-fast-on-wrong-request-media-type",
        true
      )

    parameters =
      Map.get(operation_object, "parameters", [])
      |> Enum.group_by(fn
        %{"in" => loc} ->
          loc

        %{"$ref" => ref} ->
          ["#" | ref_path] = String.split(ref, "/")
          %{"in" => loc} = get_in(spec, ref_path)
          loc
      end)

    websocket_upgrade_header_matches =
      if websocket_enabled do
        [%{"name" => "upgrade", "present_match" => true}]
      else
        []
      end

    required_header_matches =
      if missing_header_param_check do
        Map.get(parameters, "header", [])
        |> Enum.filter(fn p -> Map.get(p, "required", false) end)
        |> Enum.map(fn p -> %{"name" => Map.get(p, "name"), "present_match" => true} end)
      else
        []
      end

    request_body = Map.get(operation_object, "requestBody", %{})
    content = Map.get(request_body, "content", %{})
    request_body_optional = not Map.get(request_body, "required", false)

    media_type_regex =
      Enum.join(Map.keys(content), "|")
      |> String.replace("/", "\\/")
      |> String.replace("/*", "/[a-zA-Z0-9_-]+")

    media_type_header_matches =
      if not wrong_request_media_type_check or media_type_regex == "" do
        []
      else
        [
          %{
            "name" => "content-type",
            "string_match" => %{
              "safe_regex" => %{
                "regex" =>
                  if request_body_optional do
                    "(^$|^(#{media_type_regex})(;.*)*$)"
                  else
                    "^#{media_type_regex}(;.*)*$"
                  end
              }
            },
            "treat_missing_header_as_empty" => request_body_optional
          }
        ]
      end

    required_query_matches =
      if missing_query_param_check do
        Map.get(parameters, "query", [])
        |> Enum.filter(fn p -> Map.get(p, "required", false) end)
        |> Enum.map(fn p -> %{"name" => Map.get(p, "name"), "present_match" => true} end)
      else
        []
      end

    path_templates = Regex.scan(@path_template_regex, path)

    {cluster_route_config, clusters} =
      case servers do
        [server] ->
          {cluster_name, _uri} =
            cluster = cluster_uri_from_oas3_server(server)

          {%{"cluster" => cluster_name}, [cluster | clusters]}

        servers when length(servers) > 1 ->
          clusters_for_path =
            Enum.map(servers, fn server ->
              {cluster_uri_from_oas3_server(server),
               Map.get(server, "#{@oas3_extension_prefix}-server-weight")}
            end)

          {cluster_without_weights, cluster_with_weights} =
            Enum.map(clusters_for_path, fn {{cluster_name, _uri}, weight} ->
              {cluster_name, weight}
            end)
            |> Enum.sort_by(fn {_, weight} -> weight end, :desc)
            |> Enum.split_with(fn {_, weight} -> is_nil(weight) end)

          defined_weights = Enum.map(cluster_with_weights, fn {_, weight} -> weight end)

          min_weight =
            if length(defined_weights) > 0 do
              Enum.min(defined_weights)
            else
              0
            end

          cluster_configs =
            Enum.reduce(cluster_without_weights, cluster_with_weights, fn {cluster_name, _},
                                                                          acc ->
              [{cluster_name, max(0, min_weight - 1)} | acc]
            end)
            |> Enum.map(fn {cluster_name, weight} ->
              %{"name" => cluster_name, "weight" => weight}
            end)

          clusters_for_path_without_weights = Enum.unzip(clusters_for_path) |> elem(0)

          {%{
             "weighted_clusters" => %{
               "clusters" => cluster_configs
             }
           }, clusters ++ clusters_for_path_without_weights}
      end

    route_name = route_name(api_id, operation, path)
    [%{"url" => server_url} | _] = servers
    server = URI.parse(server_url)
    server_path = server.path || "/"

    {%{
       "name" => route_name,
       "match" =>
         %{
           "headers" => [
             %{
               "name" => ":method",
               "string_match" => %{
                 "exact" => String.upcase(operation)
               }
             }
             | required_header_matches ++
                 media_type_header_matches ++ websocket_upgrade_header_matches
           ],
           "query_parameters" => required_query_matches
         }
         |> Map.merge(path_match_policy(path_templates, path_prefix, path)),
       "route" =>
         %{
           "auto_host_rewrite" => true
         }
         |> Map.merge(websocket)
         |> Map.merge(path_rewrite_policy(path_templates, server_path, path))
         |> Map.merge(cluster_route_config)
     }, clusters}
  end

  defp path_match_policy([], path_prefix, path) do
    %{"path" => Path.join(path_prefix, path)}
  end

  defp path_match_policy(path_templates, path_prefix, path) do
    %{
      "path_match_policy" => %{
        "name" => "envoy.path.match.uri_template.uri_template_matcher",
        "typed_config" => %{
          "@type" =>
            "type.googleapis.com/envoy.extensions.path.match.uri_template.v3.UriTemplateMatchConfig",
          "path_template" =>
            Enum.reduce(path_templates, {0, Path.join(path_prefix, path)}, fn
              [path_template, @path_wildcard], {i, path_acc} ->
                {i, String.replace(path_acc, path_template, "{#{@path_wildcard}=**}")}

              [path_template, _path_variable], {i, path_acc} ->
                {i + 1, String.replace(path_acc, path_template, "{var#{i}}")}
            end)
            |> elem(1)
        }
      }
    }
  end

  defp path_rewrite_policy([], server_path, path) do
    %{"prefix_rewrite" => Path.join(server_path, path)}
  end

  defp path_rewrite_policy(path_templates, server_path, path) do
    %{
      "path_rewrite_policy" => %{
        "name" => "envoy.path.rewrite.uri_template.uri_template_rewriter",
        "typed_config" => %{
          "@type" =>
            "type.googleapis.com/envoy.extensions.path.rewrite.uri_template.v3.UriTemplateRewriteConfig",
          "path_template_rewrite" =>
            Path.join(
              server_path,
              Enum.reduce(path_templates, {0, path}, fn
                [path_template, @path_wildcard], {i, path_acc} ->
                  {i, String.replace(path_acc, path_template, "{#{@path_wildcard}}")}

                [path_template, _path_variable], {i, path_acc} ->
                  {i + 1, String.replace(path_acc, path_template, "{var#{i}}")}
              end)
              |> elem(1)
            )
        }
      }
    }
  end

  defp websocket_route(enabled) do
    %{
      "upgrade_configs" => [
        %{
          "upgrade_type" => "websocket",
          "enabled" => enabled
        }
      ]
    }
  end

  def cluster_uri_from_oas3_server(server) do
    url = Map.fetch!(server, "url")

    url =
      Map.get(server, "variables", %{})
      |> Enum.reduce(url, fn {var_name, %{"default" => default}}, acc_url ->
        String.replace(acc_url, "{#{var_name}}", default)
      end)

    # - url: "{protocol}://{hostname}"
    case URI.parse(url) do
      %URI{host: nil} ->
        raise("invalid upstream server hostname in server url '#{url}'")

      %URI{port: nil} ->
        raise("invalid upstream server port in server url '#{url}'")

      %URI{} = uri ->
        {"#{uri.scheme}://#{uri.host}:#{uri.port}", uri}
    end
  end

  def route_name(api_id, operation, path) do
    "#{api_id}-#{operation}-#{path}"
  end
end
