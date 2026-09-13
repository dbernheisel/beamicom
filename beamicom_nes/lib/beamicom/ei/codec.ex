defmodule Beamicom.EI.Codec do
  @moduledoc false
  @header 16

  def message(id, opcode, arguments \\ <<>>) do
    size = @header + byte_size(arguments)

    <<id::unsigned-native-64, size::unsigned-native-32, opcode::unsigned-native-32,
      arguments::binary>>
  end

  def u32(value), do: <<value::unsigned-native-32>>
  def u64(value), do: <<value::unsigned-native-64>>

  def string(value) do
    data = value <> <<0>>
    padding = rem(4 - rem(byte_size(data), 4), 4)
    <<byte_size(data)::unsigned-native-32, data::binary, 0::size(padding * 8)>>
  end

  def decode(buffer), do: decode(buffer, [])

  defp decode(buffer, messages) when byte_size(buffer) < @header,
    do: {Enum.reverse(messages), buffer}

  defp decode(
         <<id::unsigned-native-64, size::unsigned-native-32, opcode::unsigned-native-32,
           _::binary>> = buffer,
         messages
       )
       when size >= @header do
    if byte_size(buffer) < size do
      {Enum.reverse(messages), buffer}
    else
      argument_size = size - @header
      <<_::binary-size(@header), args::binary-size(^argument_size), rest::binary>> = buffer
      decode(rest, [{id, opcode, args} | messages])
    end
  end

  defp decode(_invalid, messages), do: {Enum.reverse(messages), <<>>}

  def take_u32(<<value::unsigned-native-32, rest::binary>>), do: {value, rest}
  def take_u64(<<value::unsigned-native-64, rest::binary>>), do: {value, rest}

  def take_string(binary) do
    {length, rest} = take_u32(binary)
    padded = length + rem(4 - rem(length, 4), 4)
    padding = padded - length
    <<data::binary-size(^length), _padding::binary-size(^padding), tail::binary>> = rest
    {data |> binary_part(0, max(length - 1, 0)), tail}
  end
end
