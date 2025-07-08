defmodule PlateReaderSystem.Camera.USBCamera do
  @moduledoc """
  Interface for USB cameras using OpenCV via Port.
  """

  use GenServer
  require Logger

  @capture_timeout 5000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def capture_frame(pid) do
    GenServer.call(pid, :capture_frame, @capture_timeout)
  end

  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  def set_property(pid, property, value) do
    GenServer.call(pid, {:set_property, property, value})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    device = Keyword.get(opts, :device, 0)
    fps = Keyword.get(opts, :fps, 30)
    width = Keyword.get(opts, :width, 1920)
    height = Keyword.get(opts, :height, 1080)

    executable = Path.join(:code.priv_dir(:plate_reader_system), "opencv_capture")

    unless File.exists?(executable) do
      {:stop, {:error, :opencv_capture_not_found}}
    else
      port_opts = [
        {:args, [to_string(device), to_string(fps), to_string(width), to_string(height)]},
        {:packet, 4},
        :binary,
        :exit_status
      ]

      port = Port.open({:spawn_executable, executable}, port_opts)

      state = %{
        port: port,
        device: device,
        fps: fps,
        width: width,
        height: height,
        frame_count: 0
      }

      Logger.info("Câmera USB iniciada - Device: #{device}, FPS: #{fps}, Resolução: #{width}x#{height}")

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:capture_frame, _from, state) do
    Port.command(state.port, "capture")

    receive do
      {port, {:data, frame_data}} when port == state.port ->
        case decode_frame(frame_data) do
          {:ok, image} ->
            new_state = %{state | frame_count: state.frame_count + 1}
            {:reply, {:ok, image}, new_state}

          error ->
            {:reply, error, state}
        end
    after
      @capture_timeout ->
        Logger.error("Timeout ao capturar frame da câmera USB")
        {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      type: :usb,
      device: state.device,
      fps: state.fps,
      resolution: "#{state.width}x#{state.height}",
      frame_count: state.frame_count
    }
    {:reply, info, state}
  end

  @impl true
  def handle_call({:set_property, property, value}, _from, state) do
    command = "set_#{property}:#{value}"
    Port.command(state.port, command)

    # Update local state if applicable
    new_state = case property do
      :fps -> %{state | fps: value}
      :width -> %{state | width: value}
      :height -> %{state | height: value}
      _ -> state
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("OpenCV capture encerrado com status: #{status}")
    {:stop, {:opencv_exit, status}, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message in USBCamera: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Closing USB camera: #{inspect(reason)}")
    Port.close(state.port)
    :ok
  end

  # Private Functions

  defp decode_frame(frame_data) do
    try do
      {:ok, image} = Image.from_binary(frame_data)
      {:ok, image}
    rescue
      e ->
        Logger.error("Error decoding frame: #{inspect(e)}")
        {:error, :decode_error}
    end
  end
end
