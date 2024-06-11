defmodule Peridiod.KV do
  @moduledoc """
  Key-Value storage for firmware variables

  KV provides functionality to read and modify firmware metadata.
  The firmware metadata contains information such as the active firmware
  slot, where the application data partition is located, etc. It may also contain
  board provisioning information like factory calibration so long as it is not
  too large.

  The metadata store is a simple key-value store where both keys and values are
  ASCII strings. Writes are expected to be infrequent and primarily done
  on firmware updates. If you expect frequent writes, it is highly recommended
  to persist the data elsewhere.

  The default KV backend loads and stores metadata to a U-Boot-formatted environment
  block. This doesn't mean that the device needs to run U-Boot. It just
  happens to be a convenient data format that's well supported.

  There are some expectations on keys. See the Peridiod README.md for
  naming conventions and expected key names. These are not enforced

  To change the KV backend, implement the `Peridiod.KVBackend` behaviour and
  configure the application environment in your
  program's `config.exs` like the following:

  ```elixir
  config :peridiod, kv_backend: {MyKeyValueBackend, options}
  ```

  ## Examples

  Getting all firmware metadata:

      iex> Peridiod.KV.get_all()
      %{
        "a.peridio_application_part0_devpath" => "/dev/mmcblk0p3",
        "a.peridio_application_part0_fstype" => "ext4",
        "a.peridio_application_part0_target" => "/root",
        "a.peridio_architecture" => "arm",
        "a.peridio_author" => "Peridio",
        "a.peridio_description" => "",
        "a.peridio_misc" => "",
        "a.peridio_platform" => "rpi0",
        "a.peridio_product" => "test_app",
        "a.peridio_uuid" => "d9492bdb-94de-5288-425e-2de6928ef99c",
        "a.peridio_vcs_identifier" => "",
        "a.peridio_version" => "0.1.0",
        "b.peridio_application_part0_devpath" => "/dev/mmcblk0p3",
        "b.peridio_application_part0_fstype" => "ext4",
        "b.peridio_application_part0_target" => "/root",
        "b.peridio_architecture" => "arm",
        "b.peridio_author" => "Peridio",
        "b.peridio_description" => "",
        "b.peridio_misc" => "",
        "b.peridio_platform" => "rpi0",
        "b.peridio_product" => "test_app",
        "b.peridio_uuid" => "4e08ad59-fa3c-5498-4a58-179b43cc1a25",
        "b.peridio_vcs_identifier" => "",
        "b.peridio_version" => "0.1.1",
        "peridio_active" => "b",
        "peridio_devpath" => "/dev/mmcblk0",
        "peridio_serial_number" => ""
      }

  Parts of the firmware metadata are global, while others pertain to a
  specific firmware slot. This is indicated by the key - data which describes
  firmware of a specific slot have keys prefixed with the name of the
  firmware slot. In the above example, `"peridio_active"` and
  `"peridio_serial_number"` are global, while `"a.peridio_version"` and
  `"b.peridio_version"` apply to the "a" and "b" firmware slots,
  respectively.

  It is also possible to get firmware metadata that only pertains to the
  currently active firmware slot:

      iex> Peridiod.KV.get_all_active()
      %{
        "peridio_application_part0_devpath" => "/dev/mmcblk0p3",
        "peridio_application_part0_fstype" => "ext4",
        "peridio_application_part0_target" => "/root",
        "peridio_architecture" => "arm",
        "peridio_author" => "Peridio",
        "peridio_description" => "",
        "peridio_misc" => "",
        "peridio_platform" => "rpi0",
        "peridio_product" => "test_app",
        "peridio_uuid" => "4e08ad59-fa3c-5498-4a58-179b43cc1a25",
        "peridio_vcs_identifier" => "",
        "peridio_version" => "0.1.1"
      }

  Note that `get_all_active/0` strips out the `a.` and `b.` prefixes.

  Further, the two functions `get/1` and `get_active/1` allow you to get a
  specific key from the firmware metadata. `get/1` requires specifying the
  entire key name, while `get_active/1` will prepend the slot prefix for you:

      iex> Peridiod.KV.get("peridio_active")
      "b"
      iex> Peridiod.KV.get("b.peridio_uuid")
      "4e08ad59-fa3c-5498-4a58-179b43cc1a25"
      iex> Peridiod.KV.get_active("peridio_uuid")
      "4e08ad59-fa3c-5498-4a58-179b43cc1a25"

  Aside from reading values from the KV store, it is also possible to write
  new values to the firmware metadata. New values may either have unique keys,
  in which case they will be added to the firmware metadata, or re-use a key,
  in which case they will overwrite the current value with that key:

      iex> :ok = Peridiod.KV.put("my_firmware_key", "my_value")
      iex> :ok = Peridiod.KV.put("peridio_serial_number", "my_new_serial_number")
      iex> Peridiod.KV.get("my_firmware_key")
      "my_value"
      iex> Peridiod.KV.get("peridio_serial_number")
      "my_new_serial_number"

  It is possible to write a collection of values at once, in order to
  minimize number of writes:

      iex> :ok = Peridiod.KV.put_map(%{"one_key" => "one_val", "two_key" => "two_val"})
      iex> Peridiod.KV.get("one_key")
      "one_val"

  Lastly, `put_active/3` and `put_active_map/2` allow you to write firmware metadata to the
  currently active firmware slot without specifying the slot prefix yourself:

      iex> :ok = Peridiod.KV.put_active("peridio_misc", "Peridio is awesome")
      iex> Peridiod.KV.get_active("peridio_misc")
      "Peridio is awesome"
  """
  use GenServer

  require Logger

  @typedoc """
  The KV store is a string -> string map

  Since the KV store is backed by things like the U-Boot environment blocks,
  the keys and values can't be just any string. For example, characters with
  the value `0` (i.e., `NULL`) are disallowed. The `=` sign is also disallowed
  in keys. Values may have embedded new lines. In general, it's recommended to
  stick with ASCII values to avoid causing trouble when working with C programs
  which also access the variables.
  """
  @type string_map() :: %{String.t() => String.t()}

  @typedoc false
  @type state() :: %{backend: module(), options: keyword(), contents: string_map()}

  @doc """
  Start the KV store server

  Options:
  * `:kv_backend` - a KV backend of the form `{module, options}` or just `module`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Get the key for only the active firmware slot
  """
  @spec get_active(String.t()) :: String.t() | nil
  def get_active(pid_or_name \\ __MODULE__, key) when is_binary(key) do
    GenServer.call(pid_or_name, {:get_active, key})
  end

  @doc """
  Get the key regardless of firmware slot
  """
  @spec get(String.t()) :: String.t() | nil
  def get(pid_or_name \\ __MODULE__, key) when is_binary(key) do
    GenServer.call(pid_or_name, {:get, key})
  end

  @doc """
  Get and update a key in a single transaction
  """
  @spec get_and_update(pid(), String.t(), (String.t() | :pop -> map())) :: String.t() | nil
  def get_and_update(pid_or_name \\ __MODULE__, key, fun) do
    GenServer.call(pid_or_name, {:get_and_update, key, fun})
  end

  @doc """
  Get all key value pairs for only the active firmware slot
  """
  @spec get_all_active(pid()) :: string_map()
  def get_all_active(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :get_all_active)
  end

  @doc """
  Get all keys regardless of firmware slot
  """
  @spec get_all(pid()) :: string_map()
  def get_all(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :get_all)
  end

  @doc """
  Get and update all keys in a single transaction
  """
  @spec get_all_and_update(pid(), (String.t() | :pop -> map())) :: String.t() | nil
  def get_all_and_update(pid_or_name \\ __MODULE__, fun) do
    GenServer.call(pid_or_name, {:get_all_and_update, fun})
  end

  @doc """
  Write a key-value pair to the firmware metadata
  """
  @spec put(pid(), String.t(), String.t()) :: :ok
  def put(pid_or_name \\ __MODULE__, key, value) when is_binary(key) and is_binary(value) do
    GenServer.call(pid_or_name, {:put, %{key => value}})
  end

  @doc """
  Write a collection of key-value pairs to the firmware metadata
  """
  @spec put_map(pid(), string_map()) :: :ok
  def put_map(pid_or_name \\ __MODULE__, kv) when is_map(kv) do
    GenServer.call(pid_or_name, {:put, kv})
  end

  @doc """
  Write a key-value pair to the active firmware slot
  """
  @spec put_active(pid(), String.t(), String.t()) :: :ok
  def put_active(pid_or_name \\ __MODULE__, key, value)
      when is_binary(key) and is_binary(value) do
    GenServer.call(pid_or_name, {:put_active, %{key => value}})
  end

  @doc """
  Write a collection of key-value pairs to the active firmware slot
  """
  @spec put_active_map(pid(), string_map()) :: :ok
  def put_active_map(pid_or_name \\ __MODULE__, kv) when is_map(kv) do
    GenServer.call(pid_or_name, {:put_active, kv})
  end

  @impl GenServer
  def init(opts) do
    {:ok, initial_state(opts)}
  end

  @impl GenServer
  def handle_call({:get_active, key}, _from, s) do
    {:reply, active(key, s), s}
  end

  def handle_call({:get, key}, _from, s) do
    {:reply, Map.get(s.contents, key), s}
  end

  def handle_call({:get_and_update, key, fun}, _from, s) do
    current = Map.get(s.contents, key)

    {reply, s} =
      case fun.(current) do
        :pop ->
          {:ok, Map.delete(current, key)}

        value ->
          do_put(%{key => value}, s)
      end

    {:reply, {reply, s}, s}
  end

  def handle_call(:get_all_active, _from, s) do
    active = active(s) <> "."
    reply = filter_trim_active(s, active)
    {:reply, reply, s}
  end

  def handle_call(:get_all, _from, s) do
    {:reply, s.contents, s}
  end

  def handle_call({:get_all_and_update, fun}, _from, s) do
    kv = fun.(s.contents)
    {reply, s} = do_put(kv, s)
    {:reply, {reply, s}, s}
  end

  def handle_call({:put, kv}, _from, s) do
    {reply, s} = do_put(kv, s)
    {:reply, reply, s}
  end

  def handle_call({:put_active, kv}, _from, s) do
    {reply, s} =
      Map.new(kv, fn {key, value} -> {"#{active(s)}.#{key}", value} end)
      |> do_put(s)

    {:reply, reply, s}
  end

  defp active(s),
    do: Map.get(s.contents, "peridio_active") || Map.get(s.contents, "nerves_fw_active", "")

  defp active(key, s) do
    Map.get(s.contents, "#{active(s)}.#{key}")
  end

  defp filter_trim_active(s, active) do
    Enum.filter(s.contents, fn {k, _} ->
      String.starts_with?(k, active)
    end)
    |> Enum.map(fn {k, v} -> {String.replace_leading(k, active, ""), v} end)
    |> Enum.into(%{})
  end

  defp do_put(kv, s) do
    case s.backend.save(kv, s.options) do
      :ok -> {:ok, %{s | contents: Map.merge(s.contents, kv)}}
      error -> {error, s}
    end
  end

  defguardp is_module(v) when is_atom(v) and not is_nil(v)

  defp initial_state(options) do
    case options[:kv_backend] do
      {backend, opts} when is_module(backend) and is_list(opts) ->
        initialize(backend, opts)

      backend when is_module(backend) ->
        initialize(backend, [])

      _ ->
        initialize(Peridiod.KVBackend.UBootEnv, [])
    end
  rescue
    error ->
      Logger.error("Peridiod has a bad KV configuration: #{inspect(error)}")
      initialize(Peridiod.KVBackend.InMemory, [])
  end

  defp initialize(backend, options) do
    case backend.load(options) do
      {:ok, contents} ->
        %{backend: backend, options: options, contents: contents}

      {:error, reason} ->
        Logger.error("Peridiod failed to load KV: #{inspect(reason)}")
        %{backend: Peridiod.KVBackend.InMemory, options: [], contents: %{}}
    end
  end
end
