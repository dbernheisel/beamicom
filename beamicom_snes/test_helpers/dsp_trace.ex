defmodule Beamicom.SNES.DSPTrace do
  @moduledoc """
  Renderer-aware trace driver for focused S-DSP reference vectors.

  When the public DSP exposes `clock/4`, the driver uses it directly. The
  boundary fallback keeps the vectors usable against revisions whose smallest
  public step is one sample.
  """

  import Bitwise

  alias Beamicom.SNES.DSP

  @hash_schema_version 1

  defstruct dsp: nil,
            ram: nil,
            renderer: :native,
            renderer_id: "native",
            renderer_version: 1,
            vector_id: "ad-hoc",
            vector_version: 1,
            clock: 0,
            sample_phase: 0,
            sample_count: 0,
            pcm_chunks: []

  def new(opts \\ []) do
    renderer = Keyword.get(opts, :renderer, :native)
    dsp = Keyword.get_lazy(opts, :dsp, &DSP.new/0)

    sample_phase =
      if function_exported?(DSP, :phase, 1), do: DSP.phase(dsp), else: 0

    %__MODULE__{
      dsp: dsp,
      ram:
        Keyword.get_lazy(opts, :ram, fn ->
          :array.new(0x10000, default: 0, fixed: true)
        end),
      renderer: renderer,
      renderer_id: Keyword.get(opts, :renderer_id, renderer_id(renderer)),
      renderer_version: Keyword.get(opts, :renderer_version, 1),
      vector_id: Keyword.get(opts, :vector_id, "ad-hoc"),
      vector_version: Keyword.get(opts, :vector_version, 1),
      sample_phase: sample_phase
    }
  end

  def run(vector, opts \\ []) do
    vector
    |> new_from_vector(opts)
    |> apply_actions(Map.get(vector, :setup, []))
    |> apply_actions(Map.get(vector, :actions, []))
  end

  def apply_actions(%__MODULE__{} = trace, actions) do
    Enum.reduce(actions, trace, &apply_action/2)
  end

  def write_ram(%__MODULE__{} = trace, address, value) do
    %{trace | ram: :array.set(address &&& 0xFFFF, value &&& 0xFF, trace.ram)}
  end

  def write_register(%__MODULE__{} = trace, address, value) do
    %{trace | dsp: DSP.write(trace.dsp, address, value)}
  end

  def clock(%__MODULE__{} = trace), do: advance_clocks(trace, 1)

  def advance_clocks(%__MODULE__{} = trace, clocks)
      when is_integer(clocks) and clocks >= 0 do
    if function_exported?(DSP, :clock, 4) do
      {dsp, chunk} = DSP.clock(trace.dsp, trace.ram, clocks, trace.renderer)
      store_result(trace, dsp, chunk, clocks)
    else
      advance_boundary_clocks(trace, clocks)
    end
  end

  def render_samples(%__MODULE__{} = trace, samples)
      when is_integer(samples) and samples >= 0 do
    {dsp, chunk} = DSP.render(trace.dsp, trace.ram, samples, trace.renderer)
    store_result(trace, dsp, chunk, samples * 32)
  end

  defp advance_boundary_clocks(trace, clocks) do
    samples = div(trace.sample_phase + clocks, 32)
    sample_phase = rem(trace.sample_phase + clocks, 32)

    trace
    |> render_without_advancing_clock(samples)
    |> Map.put(:clock, trace.clock + clocks)
    |> Map.put(:sample_phase, sample_phase)
  end

  def pcm(%__MODULE__{pcm_chunks: chunks}) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  def read_register(%__MODULE__{} = trace, address), do: DSP.read(trace.dsp, address)
  def read_voice(%__MODULE__{} = trace, index), do: DSP.voice(trace.dsp, index)
  def read_ram(%__MODULE__{} = trace, address), do: :array.get(address &&& 0xFFFF, trace.ram)

  def snapshot(%__MODULE__{} = trace, opts \\ []) do
    register_addresses = Keyword.get(opts, :registers, Enum.to_list(0..0x7F))
    voice_indices = Keyword.get(opts, :voices, Enum.to_list(0..7))
    ram_addresses = Keyword.get(opts, :ram, [])

    %{
      clock: trace.clock,
      sample_count: trace.sample_count,
      sample_phase: trace.sample_phase,
      pcm: pcm(trace),
      dsp: dsp_state(trace.dsp),
      registers: for(address <- register_addresses, do: {address, read_register(trace, address)}),
      voices: for(index <- voice_indices, do: {index, voice_state(read_voice(trace, index))}),
      ram: for(address <- ram_addresses, do: {address, read_ram(trace, address)})
    }
  end

  def golden_hashes(%__MODULE__{} = trace, opts \\ []) do
    state = trace |> snapshot(opts) |> Map.delete(:pcm)

    identity = %{
      hash_schema_version: @hash_schema_version,
      renderer_id: trace.renderer_id,
      renderer_version: trace.renderer_version,
      vector_id: trace.vector_id,
      vector_version: trace.vector_version
    }

    %{
      pcm: hash({identity, pcm(trace)}),
      state: hash({identity, state})
    }
  end

  def compare(expected, actual, opts \\ []) do
    expected = comparable(expected, opts)
    actual = comparable(actual, opts)

    with :ok <- compare_pcm(expected, actual),
         :ok <- compare_field(expected, actual, :clock),
         :ok <- compare_field(expected, actual, :sample_count),
         :ok <- compare_field(expected, actual, :sample_phase),
         :ok <- compare_pairs(expected, actual, :registers, "register"),
         :ok <- compare_voices(expected, actual),
         :ok <- compare_dsp(expected, actual),
         :ok <- compare_pairs(expected, actual, :ram, "RAM") do
      :ok
    end
  end

  defp new_from_vector(vector, opts) do
    new(
      Keyword.merge(
        [
          vector_id: Map.fetch!(vector, :id),
          vector_version: Map.fetch!(vector, :version),
          renderer: Keyword.get(opts, :renderer, :native)
        ],
        opts
      )
    )
  end

  defp apply_action({:write_ram, address, value}, trace), do: write_ram(trace, address, value)

  defp apply_action({:write_ram, entries}, trace) when is_list(entries) do
    Enum.reduce(entries, trace, fn {address, value}, trace -> write_ram(trace, address, value) end)
  end

  defp apply_action({:write_register, address, value}, trace),
    do: write_register(trace, address, value)

  defp apply_action({:write_registers, entries}, trace) do
    Enum.reduce(entries, trace, fn {address, value}, trace ->
      write_register(trace, address, value)
    end)
  end

  defp apply_action(:clock, trace), do: clock(trace)
  defp apply_action({:advance_clocks, clocks}, trace), do: advance_clocks(trace, clocks)
  defp apply_action({:render_samples, samples}, trace), do: render_samples(trace, samples)

  defp render_without_advancing_clock(trace, 0), do: trace

  defp render_without_advancing_clock(trace, samples) do
    {dsp, chunk} = DSP.render(trace.dsp, trace.ram, samples, trace.renderer)

    %{
      trace
      | dsp: dsp,
        sample_count: trace.sample_count + samples,
        pcm_chunks: [chunk | trace.pcm_chunks]
    }
  end

  defp store_result(trace, dsp, chunk, clocks) do
    sample_phase =
      if function_exported?(DSP, :phase, 1),
        do: DSP.phase(dsp),
        else: rem(trace.sample_phase + clocks, 32)

    %{
      trace
      | dsp: dsp,
        clock: trace.clock + clocks,
        sample_phase: sample_phase,
        sample_count: trace.sample_count + div(byte_size(chunk), 4),
        pcm_chunks: [chunk | trace.pcm_chunks]
    }
  end

  defp renderer_id(:native), do: "native"
  defp renderer_id(renderer) when is_atom(renderer), do: Atom.to_string(renderer)

  defp dsp_state(dsp), do: dsp |> Map.from_struct() |> Map.drop([:registers, :voices])
  defp voice_state(voice) when is_struct(voice), do: Map.from_struct(voice)
  defp voice_state(voice) when is_map(voice), do: voice

  defp hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp comparable(%__MODULE__{} = trace, opts), do: snapshot(trace, opts)
  defp comparable(snapshot, _opts) when is_map(snapshot), do: snapshot

  defp compare_pcm(%{pcm: expected}, %{pcm: actual}) do
    expected_frames = pcm_frames(expected)
    actual_frames = pcm_frames(actual)

    case first_list_difference(expected_frames, actual_frames) do
      nil ->
        :ok

      {sample_index, expected_frame, actual_frame} ->
        {channel, expected_value, actual_value} = frame_difference(expected_frame, actual_frame)

        {:error,
         "PCM divergence at clock #{(sample_index + 1) * 32}, sample #{sample_index}, " <>
           "channel #{channel}: expected #{inspect(expected_value)}, " <>
           "actual #{inspect(actual_value)}"}
    end
  end

  defp compare_field(expected, actual, field) do
    if Map.fetch!(expected, field) == Map.fetch!(actual, field) do
      :ok
    else
      {:error,
       "trace divergence at clock #{actual.clock}, sample #{actual.sample_count}, #{field}: " <>
         "expected #{inspect(Map.fetch!(expected, field))}, " <>
         "actual #{inspect(Map.fetch!(actual, field))}"}
    end
  end

  defp compare_dsp(expected, actual) do
    case first_map_difference(expected.dsp, actual.dsp) do
      nil ->
        :ok

      {field, expected_value, actual_value} ->
        {:error,
         "DSP state divergence at clock #{actual.clock}, sample #{actual.sample_count}, " <>
           "#{field}: expected #{inspect(expected_value)}, actual #{inspect(actual_value)}"}
    end
  end

  defp compare_pairs(expected, actual, field, label) do
    case first_pair_difference(Map.fetch!(expected, field), Map.fetch!(actual, field)) do
      nil ->
        :ok

      {address, expected_value, actual_value} ->
        {:error,
         "#{label} divergence at clock #{actual.clock}, sample #{actual.sample_count}, " <>
           "address #{hex(address)}: expected #{inspect(expected_value)}, " <>
           "actual #{inspect(actual_value)}"}
    end
  end

  defp compare_voices(expected, actual) do
    case first_pair_difference(expected.voices, actual.voices) do
      nil ->
        :ok

      {index, expected_voice, actual_voice} ->
        {field, expected_value, actual_value} = first_map_difference(expected_voice, actual_voice)

        {:error,
         "voice #{index} divergence at clock #{actual.clock}, sample #{actual.sample_count}, " <>
           "#{field}: expected #{inspect(expected_value)}, actual #{inspect(actual_value)}"}
    end
  end

  defp first_pair_difference(expected, actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.find_value(fn
      {{key, value}, {key, value}} ->
        nil

      {{key, expected_value}, {key, actual_value}} ->
        {key, expected_value, actual_value}

      {{expected_key, expected_value}, {actual_key, actual_value}} ->
        {min(expected_key, actual_key), {expected_key, expected_value},
         {actual_key, actual_value}}
    end)
    |> case do
      nil when length(expected) == length(actual) -> nil
      nil -> pair_length_difference(expected, actual)
      difference -> difference
    end
  end

  defp first_list_difference(expected, actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{value, value}, _index} -> nil
      {{expected_value, actual_value}, index} -> {index, expected_value, actual_value}
    end)
    |> case do
      nil when length(expected) == length(actual) ->
        nil

      nil ->
        index = min(length(expected), length(actual))
        {index, Enum.at(expected, index, :end), Enum.at(actual, index, :end)}

      difference ->
        difference
    end
  end

  defp first_map_difference(expected, actual) do
    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(actual))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find_value(fn key ->
      expected_value = Map.fetch(expected, key)
      actual_value = Map.fetch(actual, key)

      if expected_value == actual_value, do: nil, else: {key, expected_value, actual_value}
    end)
  end

  defp pair_length_difference(expected, actual) do
    index = min(length(expected), length(actual))
    expected_pair = Enum.at(expected, index, {:end, :end})
    actual_pair = Enum.at(actual, index, {:end, :end})

    case {expected_pair, actual_pair} do
      {{key, expected_value}, {key, actual_value}} ->
        {key, expected_value, actual_value}

      {{expected_key, expected_value}, {actual_key, actual_value}} ->
        {index, {expected_key, expected_value}, {actual_key, actual_value}}
    end
  end

  defp pcm_frames(pcm) do
    for <<left::signed-little-16, right::signed-little-16 <- pcm>>, do: {left, right}
  end

  defp frame_difference(:end, actual), do: {:frame, :end, actual}
  defp frame_difference(expected, :end), do: {:frame, expected, :end}
  defp frame_difference({left, right}, {actual_left, right}), do: {:left, left, actual_left}

  defp frame_difference({_left, right}, {_actual_left, actual_right}),
    do: {:right, right, actual_right}

  defp hex(address), do: "0x" <> String.pad_leading(Integer.to_string(address, 16), 4, "0")
end
