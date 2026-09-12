alias NxNes.NativeAPU, as: A
name = fn s -> s.__struct__ |> Module.split() |> List.last() end
field = fn k -> if k == :const, do: "constant", else: Atom.to_string(k) end
s = A.template()
structs = [s.pulse1, s.noise, s.triangle, s]

header =
  for s <- structs do
    members =
      for {k, v} <- A.fields(s) do
        type =
          cond do
            is_struct(v) -> name.(v)
            is_float(v) -> "double"
            true -> "int64_t"
          end

        "  #{type} #{field.(k)};\n"
      end

    ["typedef struct {\n", members, "} #{name.(s)};\n"]
  end

validate = fn rec, s, prefix ->
  for {k, v} <- A.fields(s) do
    path = prefix <> field.(k)

    cond do
      is_struct(v) ->
        rec.(rec, v, path <> ".")

      is_float(v) ->
        "if (!isfinite(#{path}) || fabs(#{path}) > 1e6) return 0;\n"

      true ->
        max =
          cond do
            is_boolean(v) -> 1
            k == :duty -> 3
            k in [:vol, :env_decay] -> 15
            k == :sweep_shift -> 7
            k in [:p1_seq, :p2_seq, :m5p1_seq, :m5p2_seq] -> 7
            k == :tri_seq -> 31
            k == :noise_shift -> 32767
            k == :m5pcm -> 255
            true -> 1_000_000
          end

        "if (#{path} < 0 || #{path} > #{max}) return 0;\n"
    end
  end
end

tables =
  for {name, values} <- [
        {"pulse_table",
         for(n <- 0..30, do: if(n == 0, do: 0.0, else: 95.52 / (8128.0 / n + 100)))},
        {"tnd_table",
         for(n <- 0..202, do: if(n == 0, do: 0.0, else: 163.67 / (24329.0 / n + 100)))},
        {"m5_table", for(n <- 0..30, do: if(n == 0, do: 0.0, else: 95.88 / (8128 / n + 100)))},
        {"pcm_table", for(n <- 0..255, do: n / 255 * 0.25)}
      ] do
    "static const double #{name}[] = {#{Enum.map_join(values, ",", &Float.to_string/1)}};\n"
  end

File.mkdir_p!("tmp")

File.write!("tmp/apu_state.h", [
  header,
  tables,
  "static int valid(const APU *s) {\n",
  validate.(validate, s, "s->"),
  "return s->sample_acc >= 0 && s->sample_acc < 1 && (s->frame_mode == 4 || s->frame_mode == 5) && s->seq_cycle < (s->frame_mode == 5 ? 37282 : 29830) && s->m5seq < 7457;\n}\n",
  "_Static_assert(sizeof(APU) == #{byte_size(A.pack(s))}, \"state layout mismatch\");\n"
])

include = Path.join([to_string(:code.root_dir()), "usr", "include"])

sanitize =
  if System.get_env("NATIVE_SANITIZE") == "1",
    do: ["-fsanitize=undefined", "-fno-sanitize-recover=all"],
    else: []

{out, code} =
  System.cmd(
    "cc",
    sanitize ++
      [
        "-std=c11",
        "-O3",
        "-g",
        "-fPIC",
        "-shared",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-ffp-contract=off",
        "-fno-fast-math",
        "-I" <> include,
        "-Itmp",
        "native/apu.c",
        "-o",
        "tmp/native_apu.so",
        "-lm"
      ], stderr_to_stdout: true)

IO.write(out)
if code != 0, do: raise("native build failed")
IO.puts("Built tmp/native_apu.so; run benchmarks/tests in a fresh VM.")
