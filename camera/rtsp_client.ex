defmodule PlateReaderSystem.Camera.RTSPClient do
  @moduledoc """
  RTSP client for IP cameras using FFmpeg.
  """

  use GenServer
  require Logger

  @capture_timeout 10000
  @buffer_size 1024 * 1024 # 1MB

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

  def reconnect(pid) do
    GenServer.cast(pid, :reconnect)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %{
      url: build_rtsp_url(opts),
      original_url: Keyword.fetch!(opts, :url),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      fps: Keyword.get(opts, :fps, 25),
      port: nil,
      buffer: <<>>,
      frame_count: 0,
      connected: false,
      reconnect_timer: nil
    }

    # Start async conn
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    Logger.info("Connecting to a RTSP camera: #{state.original_url}")

    case start_ffmpeg(state.url) do
      {:ok, port} ->
        Logger.info("RTSP connection established")
        {:noreply, %{state | port: port, connected: true, buffer: <<>>}}

      {:error, reason} ->
        Logger.error("RTSP connection failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    if state.port do
      Port.close(state.port)
    end

    send(self(), :connect)
    {:noreply, %{state | port: nil, connected: false, reconnect_timer: nil}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Add buffer data
    new_buffer = state.buffer <> data

    # Try to extract JPEG frames
    {frames, remaining_buffer} = extract_frames(new_buffer)

    # Process extracteds frames (keep the last)
    new_state = case frames do
      [] ->
        %{state | buffer: remaining_buffer}
      frames ->
        %{state |
          buffer: remaining_buffer,
          frame_count: state.frame_count + length(frames)
        }
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warn("FFmpeg killed with status: #{status}")
    schedule_reconnect(%{state | port: nil, connected: false})
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unknown message of RTSPClient: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:capture_frame, _from, state) do
    if state.connected do
      # Extract a most recent frame from buffer
      case extract_latest_frame(state.buffer) do
        {:ok, frame_data} ->
          case decode_frame(frame_data) do
            {:ok, image} ->
              {:reply, {:ok, image}, state}
            error ->
              {:reply, error, state}
          end

        :no_frame ->
          # Wait for most data
          Process.sleep(100)
          case extract_latest_frame(state.buffer) do
            {:ok, frame_data} ->
              case decode_frame(frame_data) do
                {:ok, image} ->
                  {:reply, {:ok, image}, state}
                error ->
                  {:reply, error, state}
              end
            :no_frame ->
              {:reply, {:error, :no_frame}, state}
          end
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      type: :rtsp,
      url: state.original_url,
      connected: state.connected,
      frame_count: state.frame_count,
      buffer_size: byte_size(state.buffer)
    }
    {:reply, info, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    send(self(), :reconnect)
    {:noreply, %{state | reconnect_timer: nil}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Encerrando cliente RTSP: #{inspect(reason)}")

    if state.port do
      Port.close(state.port)
    end

    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    :ok
  end

  # Private Functions

  defp build_rtsp_url(opts) do
    base_url = Keyword.fetch!(opts, :url)
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)

    if username && password do
      case URI.parse(base_url) do
        %URI{} = uri ->
          %{uri | userinfo: "#{username}:#{password}"}
          |> URI.to_string()
        _ ->
          base_url
      end
    else
      base_url
    end
  end

  defp start_ffmpeg(url) do
    try do
      port_opts = [
        {:args, [
          "-rtsp_transport", "tcp",
          "-i", url,
          "-f", "image2pipe",
          "-vcodec", "mjpeg",
          "-fps_mode", "vfr",
          "-"
        ]},
        {:packet, 0},
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ]

      port = Port.open({:spawn_executable, System.find_executable("ffmpeg")}, port_opts)
      {:ok, port}
    rescue
      e ->
        {:error, e}
    end
  end

  defp schedule_reconnect(state) do
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    timer = Process.send_after(self(), :reconnect, 5000)
    {:noreply, %{state | reconnect_timer: timer}}
  end

  defp extract_frames(buffer) do
    extract_frames(buffer, [])
  end

  defp extract_frames(buffer, frames) do
    case find_jpeg_boundaries(buffer) do
      {:ok, frame_data, remaining} ->
        extract_frames(remaining, [frame_data | frames])

      :incomplete ->
        {Enum.reverse(frames), buffer}
    end
  end

  defp extract_latest_frame(buffer) do
    case find_last_complete_jpeg(buffer) do
      {:ok, frame_data} -> {:ok, frame_data}
      :no_frame -> :no_frame
    end
  end

  defp find_jpeg_boundaries(buffer) do
    jpeg_start = <<0xFF, 0xD8>>
    jpeg_end = <<0xFF, 0xD9>>

    case :binary.match(buffer, jpeg_start) do
      {start_pos, 2} ->
        remaining_from_start = :binary.part(buffer, start_pos, byte_size(buffer) - start_pos)

        case :binary.match(remaining_from_start, jpeg_end) do
          {end_pos, 2} ->
            frame_size = end_pos + 2
            frame = :binary.part(remaining_from_start, 0, frame_size)
            rest = :binary.part(remaining_from_start, frame_size, byte_size(remaining_from_start) - frame_size)
            {:ok, frame, rest}

          :nomatch ->
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp find_last_complete_jpeg(buffer) do
    # Search for a last complete JPEG in buffer
    jpeg_start = <<0xFF, 0xD8>>
    jpeg_end = <<0xFF, 0xD9>>

    # Find all start positions
    starts = find_all_positions(buffer, jpeg_start)

    # Try from last to first
    Enum.reverse(starts)
    |> Enum.find_value(:no_frame, fn start_pos ->
      remaining = :binary.part(buffer, start_pos, byte_size(buffer) - start_pos)

      case :binary.match(remaining, jpeg_end) do
        {end_pos, 2} ->
          frame_size = end_pos + 2
          {:ok, :binary.part(remaining, 0, frame_size)}

        :nomatch ->
          nil
      end
    end)
  end

  defp find_all_positions(buffer, pattern) do
    find_all_positions(buffer, pattern, 0, [])
  end

  defp find_all_positions(buffer, pattern, offset, positions) do
    case :binary.match(buffer, pattern, [{:scope, {offset, byte_size(buffer) - offset}}]) do
      {pos, len} ->
        find_all_positions(buffer, pattern, pos + len, [pos | positions])

      :nomatch ->
        Enum.reverse(positions)
    end
  end

  defp decode_frame(frame_data) do
    try do
      {:ok, image} = Image.from_binary(frame_data)
      {:ok, image}
    rescue
      e ->
        Logger.error("Error decoding a RTSP frame: #{inspect(e)}")
        {:error, :decode_error}
    end
  end
end
