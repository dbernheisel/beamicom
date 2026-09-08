defmodule Beamicom.GB.BoundedZlib do
  @moduledoc false

  @doc "Inflates a zlib stream while refusing output beyond `maximum_bytes`."
  @spec inflate(iodata(), non_neg_integer()) :: {:ok, binary()} | {:error, :too_large | :invalid}
  def inflate(compressed, maximum_bytes)
      when (is_binary(compressed) or is_list(compressed)) and is_integer(maximum_bytes) and
             maximum_bytes >= 0 do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream)
      inflate_chunks(stream, :zlib.safeInflate(stream, compressed), maximum_bytes, 0, [])
    rescue
      _error -> {:error, :invalid}
    catch
      _kind, _reason -> {:error, :invalid}
    after
      try do
        :zlib.inflateEnd(stream)
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end

      :zlib.close(stream)
    end
  end

  defp inflate_chunks(stream, {status, chunk}, maximum, size, chunks)
       when status in [:continue, :finished] do
    chunk_size = IO.iodata_length(chunk)
    new_size = size + chunk_size

    cond do
      new_size > maximum ->
        {:error, :too_large}

      status == :finished ->
        {:ok, chunks |> :lists.reverse([chunk]) |> IO.iodata_to_binary()}

      true ->
        inflate_chunks(
          stream,
          :zlib.safeInflate(stream, []),
          maximum,
          new_size,
          [chunk | chunks]
        )
    end
  end

  defp inflate_chunks(_stream, _result, _maximum, _size, _chunks), do: {:error, :invalid}
end
