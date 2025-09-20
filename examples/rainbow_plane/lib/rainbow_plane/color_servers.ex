defmodule RainbowPlane.ColorServers do
  alias RainbowPlane.Helpers

  def start_n(n_clients, n_colors) do
    if __MODULE__ not in :ets.all() do
      :ets.new(__MODULE__, [:named_table, :public])
    end

    :ets.foldl(
      fn {i, %{pid: pid}}, acc ->
        DynamicSupervisor.terminate_child(RainbowPlane.BanditSupervisor, pid)
        :ets.delete(__MODULE__, i)
        [pid | acc]
      end,
      [],
      __MODULE__
    )

    Enum.each(0..(n_colors - 1), fn i ->
      color = Helpers.color_on_the_rainbow(i, n_colors)
      port = 40000 + i
      start_server(port, color, n_clients)
    end)
  end

  def get do
    :ets.tab2list(__MODULE__) |> Enum.map(fn {_i, server} -> server end)
  end

  defp start_server(port, color, n_clients) do
    child_spec =
      Bandit.child_spec(
        plug: {__MODULE__, %{color: color, i: port, n: n_clients}},
        thousand_island_options: [
          transport_options: [
            reuseaddr: true
          ]
        ],
        scheme: :http,
        port: port,
        ip: :loopback
      )

    {:ok, pid} =
      DynamicSupervisor.start_child(RainbowPlane.BanditSupervisor, child_spec) |> IO.inspect()

    :ets.insert(
      __MODULE__,
      {port, %{pid: pid, port: port, name: "color-#{port}", count: 0, weight: 1}}
    )
  end

  def init(opts) do
    opts
  end

  def call(%Plug.Conn{request_path: request_path} = conn, opts) do
    html =
      case request_path do
        "/color.json" ->
          """
                {"r": #{opts.color.r}, "g": #{opts.color.g}, "b": #{opts.color.b}}
          """

        "/color" ->
          """
                <!DOCTYPE html>
          <html>
          <style>
          body {
          transition: background-color 0.8s ease;
          }
          .flash {
          animation: flash-scale 0.5s ease;
          }
          @keyframes flash-scale {
          0% { transform: scale(1); }
          50% { transform: scale(1.05); }
          100% { transform: scale(1); }
          }
          </style>
          <body>
            </body>
          <script>
          var r = #{opts.color.r};
          var g = #{opts.color.g};
          var b = #{opts.color.b};
          var rainbow_session_id = "";
          setInterval(function() {
            fetch('/color.json', {headers: {"rainbow-session": rainbow_session_id}})
            .then(response => {
              var sid = response.headers.get("rainbow-session");
              if (sid) {
                rainbow_session_id = sid;
              }
              return response.json()
            })
            .then(color => {
              document.body.style.backgroundColor =
                `rgb(${color.r}, ${color.g}, ${color.b})`;
                // Add flash effect
                document.body.classList.add('flash');

                // Remove flash class after animation completes
                setTimeout(() => {
                  document.body.classList.remove('flash');
                }, 500);
              })
              .catch(console.error);
            }, 1000);
          </script>
          </html>
          """

        "/" ->
          """
                <!DOCTYPE html>
          <html lang="en">
          <head>
          <meta charset="UTF-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>Responsive Iframe Grid</title>
          <style>
          body {
            margin: 0;
            padding: 10px;
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            justify-content: center;
            background: #000;
          }
          iframe {
            flex: 1 1 100px; /* grow, shrink, base width */
            height: 100px;
            border: 2px solid #333;
            box-sizing: border-box;
            min-width: 100px;
            max-width: 100px;
          }
          </style>
          </head>
          <body>
          #{Enum.map(0..(opts.n - 1), fn _i -> """
            <iframe sandbox="allow-scripts" src="http://localhost:8080/color"></iframe>
            """ end)}
          </body>
          </html>
          """

        _ ->
          ""
      end

    Plug.Conn.send_resp(conn, 200, html)
    |> Plug.Conn.halt()
  end
end
