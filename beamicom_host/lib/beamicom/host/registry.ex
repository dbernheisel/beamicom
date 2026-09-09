defmodule Beamicom.Host.Registry do
  @moduledoc """
  Builds small, application-facing core registries from `Beamicom.Host.System`
  implementations.

  A system's identifier, media extensions, and audio/video/input descriptions
  come from the system itself. Hosts only declare which systems they ship and,
  when needed, additional container extensions or identifying magic bytes.
  """

  @type runtime :: atom()
  @type system_entry :: {module(), runtime()}
  @type signature :: {binary(), module()}

  defmacro __using__(options) do
    systems =
      for {system, runtime} <- Keyword.fetch!(options, :systems),
          do: {Macro.expand(system, __CALLER__), runtime}

    extra_extensions =
      for {extension, system} <- Keyword.get(options, :extra_extensions, []),
          do: {extension, Macro.expand(system, __CALLER__)}

    signatures =
      for {signature, system} <- Keyword.get(options, :signatures, []),
          do: {eval_literal!(signature, __CALLER__), Macro.expand(system, __CALLER__)}

    quote do
      @enforce_keys [:id, :system, :runtime, :capabilities]
      defstruct @enforce_keys

      @type runtime :: atom()
      @type t :: %__MODULE__{
              id: atom(),
              system: module(),
              runtime: runtime(),
              capabilities: map()
            }

      @doc false
      def __host_registry__ do
        {
          unquote(Macro.escape(systems)),
          unquote(Macro.escape(extra_extensions)),
          unquote(Macro.escape(signatures))
        }
      end

      @spec resolve(Path.t()) ::
              {:ok, t()} | {:error, {:unsupported_media_extension, String.t()}}
      def resolve(path), do: Beamicom.Host.Registry.resolve(__MODULE__, path)

      @spec resolve(Path.t(), binary()) ::
              {:ok, t()} | {:error, {:unsupported_media_extension, String.t()}}
      def resolve(path, media), do: Beamicom.Host.Registry.resolve(__MODULE__, path, media)

      @spec load(t(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
      def load(core, media, options \\ [])

      def load(%__MODULE__{system: system}, media, options),
        do: Beamicom.Host.Registry.load(system, media, options)
    end
  end

  defp eval_literal!(quoted, caller) do
    {value, []} = Code.eval_quoted(quoted, [], caller)
    value
  end

  @doc "Resolve a path, optionally using leading media bytes before its extension."
  @spec resolve(module(), Path.t(), binary() | nil) ::
          {:ok, struct()} | {:error, {:unsupported_media_extension, String.t()}}
  def resolve(registry, path, media \\ nil) when is_atom(registry) and is_binary(path) do
    {systems, extra_extensions, signatures} = registry.__host_registry__()

    case signature_system(media, signatures) do
      nil -> resolve_extension(registry, systems, extra_extensions, Path.extname(path))
      system -> descriptor(registry, systems, system)
    end
  end

  @doc "Load media through a registered system without letting malformed media exit its host."
  @spec load(module(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def load(system, media, options) when is_atom(system) and is_binary(media) do
    system.load(media, options)
  rescue
    exception -> {:error, {:media_load_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:media_load_failed, {kind, reason}}}
  end

  defp resolve_extension(registry, systems, extra_extensions, path_extension) do
    extension = String.downcase(path_extension)

    system =
      case List.keyfind(extra_extensions, extension, 0) do
        {^extension, system} -> system
        nil -> Enum.find_value(systems, &system_for_extension(&1, extension))
      end

    case system do
      nil -> {:error, {:unsupported_media_extension, extension}}
      system -> descriptor(registry, systems, system)
    end
  end

  defp system_for_extension({system, _runtime}, extension) do
    capabilities = system.capabilities()
    if extension in Map.fetch!(capabilities, :media_extensions), do: system
  end

  defp descriptor(registry, systems, system) do
    case List.keyfind(systems, system, 0) do
      {^system, runtime} ->
        capabilities = system.capabilities()

        {:ok,
         struct!(registry,
           id: system.id(),
           system: system,
           runtime: runtime,
           capabilities: capabilities
         )}

      nil ->
        {:error, {:unregistered_system, system}}
    end
  end

  defp signature_system(media, signatures) when is_binary(media) do
    Enum.find_value(signatures, fn {prefix, system} ->
      if byte_size(media) >= byte_size(prefix) and
           binary_part(media, 0, byte_size(prefix)) == prefix,
         do: system
    end)
  end

  defp signature_system(_media, _signatures), do: nil
end
