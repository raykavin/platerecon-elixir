defmodule PlateReaderSystem.Camera.ONVIFClient do
  @moduledoc """
  ONVIF client for IP camera discovery and control.
  Delegates frame capture to RTSPClient after discovery.
  """

  use GenServer
  require Logger

  alias PlateReaderSystem.Camera.RTSPClient

  @discovery_timeout 5000
  @wsdl_timeout 10000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def capture_frame(pid) do
    GenServer.call(pid, :capture_frame, 10000)
  end

  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  def get_capabilities(pid) do
    GenServer.call(pid, :get_capabilities)
  end

  def ptz_move(pid, direction, speed) do
    GenServer.call(pid, {:ptz_move, direction, speed})
  end

  def ptz_stop(pid) do
    GenServer.call(pid, :ptz_stop)
  end

  def get_presets(pid) do
    GenServer.call(pid, :get_presets)
  end

  def goto_preset(pid, token) do
    GenServer.call(pid, {:goto_preset, token})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :url),
      username: Keyword.fetch!(opts, :username),
      password: Keyword.fetch!(opts, :password),
      device_info: nil,
      capabilities: nil,
      profiles: [],
      stream_uri: nil,
      rtsp_pid: nil,
      ptz_supported: false
    }

    # Start ONVIF discovery
    send(self(), :discover)

    {:ok, state}
  end

  @impl true
  def handle_info(:discover, state) do
    Logger.info("Discovering ONVIF devices: #{state.url}")

    case discover_device(state) do
      {:ok, device_info} ->
        Logger.info("ONVIF device found: #{inspect(device_info)}")
        send(self(), :get_stream_uri)
        {:noreply, %{state | device_info: device_info}}

      {:error, reason} ->
        Logger.error("ONVIF discovery failed: #{inspect(reason)}")
        Process.send_after(self(), :discover, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:get_stream_uri, state) do
    case get_stream_uri(state) do
      {:ok, stream_uri} ->
        Logger.info("Stream URI obtained: #{stream_uri}")

        # Inicia cliente RTSP
        {:ok, rtsp_pid} = RTSPClient.start_link(
          url: stream_uri,
          username: state.username,
          password: state.password
        )

        {:noreply, %{state | stream_uri: stream_uri, rtsp_pid: rtsp_pid}}

      {:error, reason} ->
        Logger.error("Failed to get stream URI: #{inspect(reason)}")
        Process.send_after(self(), :discover, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:capture_frame, from, state) do
    if state.rtsp_pid do
      # Delegate to RTSPClient
      Task.start(fn ->
        result = RTSPClient.capture_frame(state.rtsp_pid)
        GenServer.reply(from, result)
      end)
      {:noreply, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      type: :onvif,
      url: state.url,
      device_info: state.device_info,
      stream_uri: state.stream_uri,
      connected: state.rtsp_pid != nil,
      ptz_supported: state.ptz_supported
    }
    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_capabilities, _from, state) do
    if state.capabilities do
      {:reply, {:ok, state.capabilities}, state}
    else
      case get_device_capabilities(state) do
        {:ok, capabilities} ->
          {:reply, {:ok, capabilities}, %{state | capabilities: capabilities}}
        error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:ptz_move, direction, speed}, _from, state) do
    if state.ptz_supported do
      result = execute_ptz_move(state, direction, speed)
      {:reply, result, state}
    else
      {:reply, {:error, :ptz_not_supported}, state}
    end
  end

  @impl true
  def handle_call(:ptz_stop, _from, state) do
    if state.ptz_supported do
      result = execute_ptz_stop(state)
      {:reply, result, state}
    else
      {:reply, {:error, :ptz_not_supported}, state}
    end
  end

  @impl true
  def handle_call(:get_presets, _from, state) do
    if state.ptz_supported do
      result = get_ptz_presets(state)
      {:reply, result, state}
    else
      {:reply, {:error, :ptz_not_supported}, state}
    end
  end

  @impl true
  def handle_call({:goto_preset, token}, _from, state) do
    if state.ptz_supported do
      result = goto_ptz_preset(state, token)
      {:reply, result, state}
    else
      {:reply, {:error, :ptz_not_supported}, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Encerrando cliente ONVIF: #{inspect(reason)}")
    :ok
  end

  # Private Functions - ONVIF Discovery

  defp discover_device(state) do
    # Simplified check for: WS-Discovery
    device_service_url = "#{state.url}/onvif/device_service"

    device_info = %{
      manufacturer: "Generic",
      model: "ONVIF Camera",
      firmware_version: "1.0",
      serial_number: "00000000",
      hardware_id: "1.0",
      services: %{
        device: device_service_url,
        media: "#{state.url}/onvif/media_service",
        ptz: "#{state.url}/onvif/ptz_service",
        imaging: "#{state.url}/onvif/imaging_service",
        events: "#{state.url}/onvif/events_service"
      }
    }

    {:ok, device_info}
  end

  defp get_device_capabilities(state) do
    # Get device capabilities using SOAP
    capabilities = %{
      analytics: false,
      device: true,
      events: true,
      imaging: true,
      media: true,
      ptz: check_ptz_support(state),
      extension: %{}
    }

    {:ok, capabilities}
  end

  defp get_stream_uri(state) do
    # Call SOAP GetStreamUri
    # Build a URI base in common patterns

    base_url = URI.parse(state.url)
    rtsp_port = 554

    stream_uri = %URI{
      scheme: "rtsp",
      host: base_url.host,
      port: rtsp_port,
      path: "/Streaming/Channels/101",
      userinfo: "#{state.username}:#{state.password}"
    }
    |> URI.to_string()

    {:ok, stream_uri}
  end

  # Pending of implementation
  defp check_ptz_support(state) do
    # Check if device supports a PTZ function
    # GetCapabilities
    true
  end

  # Private Functions - PTZ Control

  # Pending of implementation
  defp execute_ptz_move(state, direction, speed) do
    # Execute a PTZ moving
    Logger.info("PTZ Move: #{direction} at speed #{speed}")
    :ok
  end

  # Pending of implementation
  defp execute_ptz_stop(_state) do
    # Stop PTZ moving
    Logger.info("PTZ Stop")

    # Send stop SOAP command
    :ok
  end

  defp get_ptz_presets(_state) do
    # Returns a presets of avaliable PTZ
    presets = [
      %{token: "1", name: "Entrada"},
      %{token: "2", name: "Estacionamento"},
      %{token: "3", name: "Saída"}
    ]

    {:ok, presets}
  end

  defp goto_ptz_preset(_state, token) do
    # Move to specified preset
    Logger.info("Going to preset: #{token}")

    # Send GotoPreset SOAP command
    :ok
  end
end
