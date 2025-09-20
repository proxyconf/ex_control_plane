defmodule RainbowPlane.Helpers do
  @moduledoc """
  A simple, yet incomplete patching helper that is able to update maps and lists
  """
  def patch(list, op, [i], value) when is_list(list) do
    case op do
      :insert -> List.insert_at(list, i, value)
      :update -> List.update_at(list, i, fn _ -> value end)
    end
  end

  def patch(list, op, [i | rest], value) when is_list(list) do
    List.update_at(list, i, fn current_value -> patch(current_value, op, rest, value) end)
  end

  def patch(map, op, [k], value) when is_map(map) do
    case op do
      :insert ->
        Map.put(map, k, value)

      :update ->
        Map.update!(map, k, fn _ -> value end)
    end
  end

  def patch(map, op, [k | rest], value) when is_map(map) do
    Map.update!(map, k, fn current_value -> patch(current_value, op, rest, value) end)
  end

  def color_on_the_rainbow(i, n) do
    h = i * 360 / n
    hsv_to_rgb(h, 1.0, 1.0)
  end

  defp hsv_to_rgb(h, s, v) do
    c = v * s
    x = c * (1 - abs(:math.fmod(h / 60, 2) - 1))
    m = v - c

    {r1, g1, b1} =
      cond do
        h < 60 -> {c, x, 0}
        h < 120 -> {x, c, 0}
        h < 180 -> {0, c, x}
        h < 240 -> {0, x, c}
        h < 300 -> {x, 0, c}
        true -> {c, 0, x}
      end

    %{r: round((r1 + m) * 255), g: round((g1 + m) * 255), b: round((b1 + m) * 255)}
  end
end
