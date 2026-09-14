defmodule Beamicom.Scenic.FileDialog do
  @moduledoc """
  Small cross-platform facade for native file and directory selectors.

  Dialogs select paths only. Callers remain responsible for reading, validating,
  encoding, and writing files. The shell should invoke these blocking calls from
  a supervised task rather than from a Scenic scene process.

  Filters use `{label, extensions}` tuples. Extensions omit the leading dot:

      FileDialog.open([{"ROMs", ["nes", "gb", "gbc"]}], File.cwd!())
  """

  alias Beamicom.Scenic.FileDialog.Native

  @type filter :: {String.t(), [String.t()]}
  @type result :: {:ok, String.t()} | :cancel | {:error, term()}

  @spec open([filter()], String.t() | nil) :: result()
  def open(filters, initial_directory \\ nil) do
    with {:ok, filters} <- normalize_filters(filters),
         {:ok, initial_directory} <- normalize_directory(initial_directory) do
      backend()
      |> apply(:open, ["Load media", filters, initial_directory])
      |> normalize_result()
    end
  end

  @spec save([filter()], String.t() | nil, String.t() | nil) :: result()
  def save(filters, initial_directory \\ nil, default_name \\ nil) do
    with {:ok, filters} <- normalize_filters(filters),
         {:ok, initial_directory} <- normalize_directory(initial_directory),
         {:ok, default_name} <- normalize_default_name(default_name) do
      backend()
      |> apply(:save, ["Save state", filters, initial_directory, default_name])
      |> normalize_result()
    end
  end

  @spec directory(String.t() | nil) :: result()
  def directory(initial_directory \\ nil) do
    with {:ok, initial_directory} <- normalize_directory(initial_directory) do
      backend()
      |> apply(:directory, ["Select save-state folder", initial_directory])
      |> normalize_result()
    end
  end

  defp backend do
    Application.get_env(:beamicom_scenic, :file_dialog_backend, Native)
  end

  defp normalize_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn
      {label, extensions}, {:ok, normalized}
      when is_binary(label) and byte_size(label) > 0 and is_list(extensions) and
             extensions != [] ->
        case normalize_extensions(extensions) do
          {:ok, extensions} -> {:cont, {:ok, [{label, extensions} | normalized]}}
          :error -> {:halt, {:error, :invalid_filters}}
        end

      _filter, _normalized ->
        {:halt, {:error, :invalid_filters}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_filters(_filters), do: {:error, :invalid_filters}

  defp normalize_extensions(extensions) do
    Enum.reduce_while(extensions, {:ok, []}, fn
      extension, {:ok, normalized} when is_binary(extension) ->
        extension = String.trim_leading(extension, ".")

        if extension == "" or String.contains?(extension, ["/", "\\", "*"]) do
          {:halt, :error}
        else
          {:cont, {:ok, [extension | normalized]}}
        end

      _extension, _normalized ->
        {:halt, :error}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp normalize_directory(nil), do: {:ok, nil}
  defp normalize_directory(directory) when is_binary(directory), do: {:ok, Path.expand(directory)}
  defp normalize_directory(_directory), do: {:error, :invalid_initial_directory}

  defp normalize_default_name(nil), do: {:ok, nil}
  defp normalize_default_name(name) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp normalize_default_name(_name), do: {:error, :invalid_default_name}

  defp normalize_result({:ok, nil}), do: :cancel
  defp normalize_result({:ok, path}) when is_binary(path), do: {:ok, path}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(result), do: {:error, {:unexpected_native_result, result}}
end
