ExUnit.start()

# Integration tests (e.g. the full ex_webrtc pipeline) boot heavyweight native
# machinery that disrupts sibling tests in the same VM; run them in isolation
# with `mix test --only integration`.
ExUnit.configure(exclude: [:integration])
