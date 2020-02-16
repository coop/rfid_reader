defmodule RFIDReader do
  @moduledoc """
  Read from ThingMagic RFID reader.

  This process exists because the binary we use to read data from RFID
  will not read for the duration of the timeout if it isn't plugged in.
  Instead it will return immediately saying 0 tags were scanned. To
  mitigate this we always scan for the duration of the passed timeout
  regardless of how long the read takes.
  """

  use GenServer

  alias RFIDReader.Errors.InvalidReadTimeoutError
  alias RFIDReader.Errors.RFIDReadInProgressError
  alias RFIDReader.Errors.ReadTimeoutError
  alias RFIDReader.Errors.ReadError

  @read_timeout 2_000
  @read_buffer 1_000
  @timeout 5_000
  @power 1_000
  @retries 10
  @retry_interval 100

  defmodule State do
    @enforce_keys [:binary, :reader_url]
    defstruct [:binary, :reader_url, :ref, :result, :retries, read_in_progress?: false]
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def read(server, opts \\ []) do
    power = Keyword.get(opts, :power, @power)
    read_timeout = Keyword.get(opts, :read_timeout, @read_timeout)
    timeout = Keyword.get(opts, :timeout, @timeout)

    if read_timeout + @read_buffer > timeout do
      {:error, %InvalidReadTimeoutError{}}
    else
      GenServer.call(server, {:read, read_timeout, power}, timeout)
    end
  end

  @impl GenServer
  def init(opts) do
    binary = Application.app_dir(:rfid_reader, "priv/read-tags.arm")

    opts = Keyword.put_new(opts, :retries, @retries)
    opts = Keyword.put_new(opts, :binary, binary)

    {:ok, struct!(State, opts)}
  end

  @impl GenServer
  def handle_call({:read, _timeout, _power}, _from, %{read_in_progress?: true} = state) do
    {:reply, {:error, %RFIDReadInProgressError{}}, state}
  end

  @impl GenServer
  def handle_call({:read, timeout, power}, from, state) do
    pid = self()
    ref = make_ref()

    spawn(fn -> send(pid, {:handle_result, cmd(state, timeout, power), ref}) end)
    Process.send_after(self(), {:timeout, from}, timeout)

    {:noreply, %{state | read_in_progress?: true, ref: ref}}
  end

  @impl GenServer
  def handle_info({:timeout, from}, %{result: nil, retries: 0} = state) do
    GenServer.reply(from, {:error, %ReadTimeoutError{}})

    {:noreply, reset(state)}
  end

  @impl GenServer
  def handle_info({:timeout, from}, %{result: nil} = state) do
    Process.send_after(self(), {:timeout, from}, @retry_interval)
    state = Map.update!(state, :retries, &(&1 - 1))

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:timeout, from}, state) do
    result = handle_result(state.result)
    GenServer.reply(from, result)

    {:noreply, reset(state)}
  end

  @impl GenServer
  def handle_info({:handle_result, result, ref}, %{ref: ref} = state) do
    {:noreply, %{state | result: result}}
  end

  def handle_info({:handle_result, _result, _ref}, state) do
    {:noreply, state}
  end

  defp handle_result({result, 0}) do
    reads = result |> String.trim_trailing() |> String.split("\n") |> Enum.drop(5)
    tags = Enum.map(reads, fn read -> hd(String.split(read, " ", parts: 2)) end)

    {:ok, tags}
  end

  defp handle_result({result, 1}) do
    reason = result |> String.trim_trailing() |> String.split("\n") |> List.first()

    {:error, %ReadError{message: reason}}
  end

  defp cmd(state, timeout, power) do
    System.cmd(
      state.binary,
      [
        state.reader_url,
        "--ant",
        "1",
        "--timeout",
        to_string(timeout),
        "--pow",
        to_string(power)
      ],
      stderr_to_stdout: true
    )
  end

  defp reset(state) do
    %{state | result: nil, read_in_progress?: false, retries: @retries, ref: nil}
  end
end
