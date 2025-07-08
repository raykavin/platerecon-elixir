defmodule PlateReaderSystem.Detection.Supervisor do
  @moduledoc """
  Supervisor for detection processes.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Main YOLO Detector
      {PlateReaderSystem.Detection.YOLODetector, [
        model_path: Application.get_env(:plate_reader_system, :model_path),
        detection: Application.get_env(:plate_reader_system, :detection, %{})
      ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
