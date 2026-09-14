defmodule Beamicom.Scenic.FileDialog.NativeTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.FileDialog.Native

  if :os.type() == {:unix, :darwin} do
    @tag :tmp_dir
    test "reuses the macOS helper for sequential dialogs", %{tmp_dir: tmp_dir} do
      helper =
        write_helper(tmp_dir, """
        printf 'O%s|%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5" "$6"
        """)

      assert {:ok, "save|Save state|/tmp/states|game.png|png|zip"} =
               Native.mac_save(
                 "Save state",
                 [{"Save states", ["png", "zip"]}],
                 "/tmp/states",
                 "game.png",
                 helper
               )

      assert {:ok, "open|Load media|/tmp/roms||nes|gb"} =
               Native.mac_open(
                 "Load media",
                 [{"ROMs", ["nes", "gb"]}],
                 "/tmp/roms",
                 helper
               )
    end

    @tag :tmp_dir
    test "decodes selection, cancellation, and errors from the macOS helper", %{
      tmp_dir: tmp_dir
    } do
      selected = write_helper(tmp_dir, "printf 'O/tmp/日本語.nes'")
      cancelled = write_helper(tmp_dir, "printf 'C'", "cancelled")
      failed = write_helper(tmp_dir, "printf 'Epanel unavailable'", "failed")

      assert {:ok, "/tmp/日本語.nes"} = Native.mac_open("Load media", [], nil, selected)
      assert {:ok, nil} = Native.mac_directory("Select folder", nil, cancelled)
      assert {:error, "panel unavailable"} = Native.mac_open("Load media", [], nil, failed)
    end

    @tag :tmp_dir
    test "reports a macOS helper launch failure", %{tmp_dir: tmp_dir} do
      missing_helper = Path.join(tmp_dir, "missing")

      assert {:error, message} = Native.mac_open("Load media", [], nil, missing_helper)
      assert message =~ "could not launch macOS file dialog helper"
    end

    defp write_helper(tmp_dir, body, name \\ "helper") do
      bundle = Path.join(tmp_dir, "#{name}.app")
      executable = Path.join(bundle, "Contents/MacOS/BeamicomFileDialog")
      identifier = "com.beamicom.scenic.test.#{:erlang.phash2(tmp_dir)}.#{name}"

      File.mkdir_p!(Path.dirname(executable))

      File.write!(
        Path.join(bundle, "Contents/Info.plist"),
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>CFBundleExecutable</key><string>BeamicomFileDialog</string>
          <key>CFBundleIdentifier</key><string>#{identifier}</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>LSUIElement</key><true/>
        </dict>
        </plist>
        """
      )

      File.write!(executable, "#!/bin/sh\nresult=$1\nshift\n{\n#{body}\n} > \"$result\"\n")
      File.chmod!(executable, 0o700)
      bundle
    end
  end
end
