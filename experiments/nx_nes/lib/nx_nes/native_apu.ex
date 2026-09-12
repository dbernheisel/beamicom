defmodule NxNes.NativeAPU do
  @moduledoc "Experimental immutable native APU state; no DMC/5B or register writes inside an interval."
  @on_load :load_nif
  @template Beamicom.NES.APU.new()
  def template, do: @template

  def fields(s),
    do: s |> Map.from_struct() |> Map.drop([:samples, :dmc, :sunsoft5b]) |> Enum.sort()

  def load_nif do
    path = Path.expand("../../tmp/native_apu", __DIR__)

    case :erlang.load_nif(String.to_charlist(path), 0) do
      :ok -> :ok
      {:error, {:load_failed, _}} -> :ok
      other -> other
    end
  end

  def pack(s) do
    if s.dmc != nil or s.sunsoft5b != nil,
      do: raise(ArgumentError, "native probe does not support DMC or Sunsoft 5B")

    encode(s)
  end

  defp encode(s) do
    for {_, v} <- fields(s), into: <<>> do
      cond do
        is_struct(v) -> encode(v)
        is_float(v) -> <<v::float-native-64>>
        is_boolean(v) -> <<if(v, do: 1, else: 0)::signed-native-64>>
        true -> <<v::signed-native-64>>
      end
    end
  end

  def unpack(binary) do
    {s, <<>>} = decode(@template, binary)
    s
  end

  defp decode(template, binary) do
    Enum.reduce(fields(template), {template, binary}, fn {k, v}, {s, bytes} ->
      {value, rest} =
        cond do
          is_struct(v) ->
            decode(v, bytes)

          is_float(v) ->
            <<x::float-native-64, rest::binary>> = bytes
            {x, rest}

          true ->
            <<x::signed-native-64, rest::binary>> = bytes
            {if(is_boolean(v), do: x != 0, else: x), rest}
        end

      {Map.put(s, k, value), rest}
    end)
  end

  @doc "Return {new immutable state, little-endian PCM, unconsumed cycles}; at most 1024 samples."
  def run(_state, _cycles), do: :erlang.nif_error(:native_apu_not_built)
end
