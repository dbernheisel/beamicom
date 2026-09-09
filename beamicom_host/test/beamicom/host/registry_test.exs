defmodule Beamicom.Host.RegistryTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.InputCapabilities

  defmodule FirstSystem do
    def id, do: :first

    def capabilities do
      %{
        media_extensions: [".one", ".first"],
        input: InputCapabilities.new(%{1 => [:a]}),
        video: %{width: 1, height: 1, frame_rate: 60.0},
        audio: %{sample_rate: 8_000, channels: 1, sample_format: :s16le}
      }
    end

    def load("raise", _options), do: raise("invalid fixture")
    def load(media, options), do: {:ok, {media, options}}
  end

  defmodule SecondSystem do
    def id, do: :second

    def capabilities do
      %{
        media_extensions: [".two"],
        input: InputCapabilities.new(%{}),
        video: %{width: 2, height: 2, frame_rate: 30.0},
        audio: %{sample_rate: 16_000, channels: 2, sample_format: :s16le}
      }
    end

    def load(media, options), do: {:ok, {media, options}}
  end

  defmodule TestRegistry do
    use Beamicom.Host.Registry,
      systems: [
        {Beamicom.Host.RegistryTest.FirstSystem, :legacy},
        {Beamicom.Host.RegistryTest.SecondSystem, :host}
      ],
      extra_extensions: [{".save", Beamicom.Host.RegistryTest.FirstSystem}],
      signatures: [{<<1, 2, 3>>, Beamicom.Host.RegistryTest.SecondSystem}]
  end

  test "derives extensions, identity, and capabilities from registered systems" do
    assert {:ok,
            %TestRegistry{
              id: :first,
              system: FirstSystem,
              runtime: :legacy,
              capabilities: %{video: %{width: 1}}
            }} = TestRegistry.resolve("GAME.ONE")

    assert {:ok, %TestRegistry{id: :second, runtime: :host}} =
             TestRegistry.resolve("game.two")

    assert {:ok, %TestRegistry{id: :first}} = TestRegistry.resolve("snapshot.save")
    assert {:error, {:unsupported_media_extension, ".zip"}} = TestRegistry.resolve("game.ZIP")
  end

  test "configured media signatures take precedence over extensions" do
    assert {:ok, %TestRegistry{id: :second}} =
             TestRegistry.resolve("renamed.one", <<1, 2, 3, 4>>)
  end

  test "loading delegates options and normalizes core exceptions" do
    {:ok, core} = TestRegistry.resolve("game.one")

    assert {:ok, {"media", [model: :test]}} =
             TestRegistry.load(core, "media", model: :test)

    assert {:error, {:media_load_failed, "invalid fixture"}} =
             TestRegistry.load(core, "raise", [])
  end
end
