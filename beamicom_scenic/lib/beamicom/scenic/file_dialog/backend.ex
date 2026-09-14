defmodule Beamicom.Scenic.FileDialog.Backend do
  @moduledoc false

  @type filter :: {String.t(), [String.t()]}
  @type result :: {:ok, String.t() | nil} | {:error, term()}

  @callback open(String.t(), [filter()], String.t() | nil) :: result()

  @callback save(String.t(), [filter()], String.t() | nil, String.t() | nil) :: result()

  @callback directory(String.t(), String.t() | nil) :: result()
end
