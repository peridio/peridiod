defmodule Peridiod.Binary.Installer.File do
  use Peridiod.Binary.Installer.Behaviour

  alias Peridiod.Binary

  def install_init(
        %Binary{
          prn: prn
        },
        %{"name" => name, "path" => path},
        _source,
        _config
      ) do
    with :ok <- File.mkdir_p(path),
         {:ok, id} <- Binary.id_from_prn(prn) do
      final_dest = Path.join([path, name])
      tmp_dest = Path.join([path, id])
      state = {tmp_dest, final_dest}
      {:ok, state}
    else
      {:error, error} ->
        {:error, error, nil}
    end
  end

  def install_update(_binary_metadata, data, {tmp_dest, _final_dest} = state) do
    File.write(tmp_dest, data, [:append, :binary])
    {:ok, state}
  end

  def install_finish(_binary_metadata, :valid_signature, _hash, {tmp_dest, final_dest} = state) do
    link_name = Path.relative_to(tmp_dest, Path.dirname(tmp_dest))

    case File.ln_s(link_name, final_dest) do
      :ok -> {:stop, :normal, state}
      {:error, error} -> {:error, error, state}
    end
  end

  def install_finish(_binary_metadata, invalid, _hash, {tmp_dest, _final_dest} = state) do
    File.rm(tmp_dest)
    {:error, invalid, state}
  end
end
