defmodule Beamicom.Scenic.FileDialog.Linux do
  @moduledoc false

  @spec open(String.t(), list(), String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def open(title, filters, initial_directory) do
    run(command_args(:open, title, filters, initial_directory, nil))
  end

  @spec save(String.t(), list(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def save(title, filters, initial_directory, default_name) do
    run(command_args(:save, title, filters, initial_directory, default_name))
  end

  @spec directory(String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def directory(title, initial_directory) do
    run(command_args(:directory, title, [], initial_directory, nil))
  end

  @doc false
  def command_args(kind, title, filters, initial_directory, default_name)
      when kind in [:open, :save, :directory] do
    ["--file-selection", "--title=#{title}"]
    |> add_kind(kind)
    |> add_initial_path(initial_directory, default_name)
    |> add_filters(filters)
  end

  defp run(arguments) do
    case System.find_executable("zenity") do
      nil ->
        {:error, "zenity is unavailable"}

      executable ->
        case System.cmd(executable, arguments) do
          {path, 0} -> {:ok, trim_line_ending(path)}
          {_output, 1} -> {:ok, nil}
          {_output, status} -> {:error, "native file selector exited with status #{status}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp add_kind(arguments, :open), do: arguments
  defp add_kind(arguments, :save), do: arguments ++ ["--save", "--confirm-overwrite"]
  defp add_kind(arguments, :directory), do: arguments ++ ["--directory"]

  defp add_initial_path(arguments, nil, nil), do: arguments

  defp add_initial_path(arguments, directory, default_name) do
    path =
      case {directory, default_name} do
        {nil, name} -> name
        {directory, nil} -> String.trim_trailing(directory, "/") <> "/"
        {directory, name} -> Path.join(directory, name)
      end

    arguments ++ ["--filename=#{path}"]
  end

  defp add_filters(arguments, filters) do
    arguments ++
      Enum.map(filters, fn {label, extensions} ->
        patterns = Enum.map_join(extensions, " ", &"*.#{&1}")
        "--file-filter=#{label} | #{patterns}"
      end)
  end

  defp trim_line_ending(path) do
    path
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
