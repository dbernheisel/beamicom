Application.load(:exla)
IO.inspect(:code.which(EXLA.Client), label: "EXLA client beam")

Application.put_env(:exla, :clients,
  probe_rocm: [
    platform: :pjrt_plugin,
    device_type: "ROCM",
    memory_fraction: 0.05,
    preallocate: false,
    plugin_path: "/tmp/dbern/exla-rocm-pjrt/unpacked/jax_plugins/xla_rocm7/xla_rocm_plugin.so"
  ]
)

Application.put_env(:exla, :default_client, :probe_rocm)
Application.ensure_all_started(:exla) |> IO.inspect()
EXLA.Client.fetch!(:probe_rocm) |> IO.inspect()
f = EXLA.jit(fn x -> Nx.add(x, 1) end, client: :probe_rocm)
f.(Nx.tensor([1, 2, 3])) |> Nx.to_flat_list() |> IO.inspect(label: "GPU result")
