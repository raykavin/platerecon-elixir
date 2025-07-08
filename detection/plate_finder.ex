defmodule PlateReaderSystem.Detection.PlateFinder do
  @moduledoc """
  Specialized in finding and processing license plate regions in images.
  Combines YOLO detections with traditional computer vision techniques.
  """

  require Logger

  alias PlateReaderSystem.OCR.Tesseract
  alias PlateReaderSystem.OCR.TextNormalizer
  alias PlateReaderSystem.OCR.PlateValidator

  @min_plate_area 3000
  @max_plate_area 80000
  @min_aspect_ratio 2.0
  @max_aspect_ratio 5.5

  defmodule PlateInfo do
    @moduledoc false
    defstruct [
      :text,
      :confidence,
      :bbox,
      :area,
      :aspect_ratio,
      :detection_method
    ]
  end

  @doc """
  Finds license plates in an image using multiple techniques.
  """
  def find_plates(image, yolo_detections \\ []) do
    # Combine multiple detection techniques
    candidates = []

    # 1. Use YOLO detections if available
    yolo_candidates = process_yolo_detections(image, yolo_detections)
    candidates = candidates ++ yolo_candidates

    # 2. Edge detection
    edge_candidates = find_by_edges(image)
    candidates = candidates ++ edge_candidates

    # 3. Color detection (white plates)
    color_candidates = find_by_color(image)
    candidates = candidates ++ color_candidates

    # 4. Text region detection
    text_candidates = find_by_text_regions(image)
    candidates = candidates ++ text_candidates

    # Remove duplicates and filter
    plates = candidates
    |> remove_duplicates()
    |> Enum.map(&process_plate_candidate(image, &1))
    |> Enum.filter(&(&1.text != "" && PlateValidator.valid?(&1.text)))
    |> Enum.sort_by(& &1.confidence, :desc)

    {:ok, plates}
  end

  # YOLO detection processing

  defp process_yolo_detections(image, detections) do
    detections
    |> Enum.map(fn detection ->
      %{
        bbox: expand_bbox(detection.bbox, 1.1),
        confidence: detection.confidence,
        method: :yolo
      }
    end)
  end

  # Edge detection

  defp find_by_edges(image) do
    gray = Image.to_grayscale!(image)

    # Apply bilateral filter to preserve edges
    filtered = Image.bilateral_filter!(gray, 11, 17, 17)

    # Detect edges with Canny
    edges = Image.canny!(filtered, 30, 200)

    # Dilation to connect components
    kernel = Image.morphology_kernel!(:rect, {3, 3})
    dilated = Image.dilate!(edges, kernel)

    # Find contours
    contours = Image.find_contours!(dilated)

    # Filter contours by plate geometry
    contours
    |> Enum.filter(&is_plate_like_contour?/1)
    |> Enum.map(fn contour ->
      %{
        bbox: contour.bbox,
        confidence: calculate_edge_confidence(contour),
        method: :edge
      }
    end)
  end

  # Color detection

  defp find_by_color(image) do
    gray = Image.to_grayscale!(image)

    # Threshold for white/bright regions
    white_mask = Image.threshold!(gray, 200, 255, :binary)

    # Morphological operations
    kernel = Image.morphology_kernel!(:rect, {5, 5})
    closed = Image.morphology!(white_mask, :close, kernel)

    # Find connected components
    components = Image.connected_components!(closed)

    # Filter by plate characteristics
    components
    |> Enum.filter(&is_plate_like_component?/1)
    |> Enum.map(fn comp ->
      %{
        bbox: comp.bbox,
        confidence: calculate_color_confidence(comp, gray),
        method: :color
      }
    end)
  end

  # Text region detection

  defp find_by_text_regions(image) do
    gray = Image.to_grayscale!(image)

    # Horizontal gradient to detect text
    grad_x = Image.sobel!(gray, :x)
    grad_x_abs = Image.abs!(grad_x)

    # Threshold and morphology
    thresh = Image.threshold!(grad_x_abs, 0, 255, :otsu)
    kernel = Image.morphology_kernel!(:rect, {20, 3})
    morph = Image.morphology!(thresh, :close, kernel)

    # Find regions
    contours = Image.find_contours!(morph)

    contours
    |> Enum.filter(&is_text_region_like?/1)
    |> Enum.map(fn contour ->
      %{
        bbox: contour.bbox,
        confidence: calculate_text_confidence(contour),
        method: :text
      }
    end)
  end

  # Candidate processing

  defp process_plate_candidate(image, candidate) do
    roi = extract_roi(image, candidate.bbox)

    # Multiple OCR attempts with different preprocessing
    ocr_results = [
      Tesseract.read_with_preprocessing(roi, :standard),
      Tesseract.read_with_preprocessing(roi, :enhanced),
      Tesseract.read_with_preprocessing(roi, :inverted)
    ]

    # Select the best result
    best_result = ocr_results
    |> Enum.filter(fn {text, _conf} -> text != "" end)
    |> Enum.max_by(fn {text, conf} ->
      score_ocr_result(text, conf)
    end, fn -> {"", 0} end)

    {text, ocr_confidence} = best_result
    normalized_text = TextNormalizer.normalize(text)

    %PlateInfo{
      text: normalized_text,
      confidence: combine_confidences(candidate.confidence, ocr_confidence),
      bbox: candidate.bbox,
      area: calculate_area(candidate.bbox),
      aspect_ratio: calculate_aspect_ratio(candidate.bbox),
      detection_method: candidate.method
    }
  end

  # Helper functions

  defp expand_bbox({x, y, w, h}, factor) do
    expand_x = round(w * (factor - 1) / 2)
    expand_y = round(h * (factor - 1) / 2)

    {
      max(0, x - expand_x),
      max(0, y - expand_y),
      w + 2 * expand_x,
      h + 2 * expand_y
    }
  end

  defp is_plate_like_contour?(contour) do
    area = contour.area
    aspect_ratio = contour.bbox.width / contour.bbox.height

    area >= @min_plate_area &&
    area <= @max_plate_area &&
    aspect_ratio >= @min_aspect_ratio &&
    aspect_ratio <= @max_aspect_ratio
  end

  defp is_plate_like_component?(component) do
    is_plate_like_contour?(component)
  end

  defp is_text_region_like?(contour) do
    is_plate_like_contour?(contour)
  end

  defp calculate_edge_confidence(contour) do
    base_confidence = 50.0

    # Bonus for ideal aspect ratio
    aspect_ratio = contour.bbox.width / contour.bbox.height
    ar_bonus = if aspect_ratio >= 2.5 && aspect_ratio <= 4.5, do: 20, else: 0

    # Bonus for ideal area
    area = contour.area
    area_bonus = cond do
      area >= 8000 && area <= 30000 -> 20
      area >= 5000 && area <= 40000 -> 10
      true -> 0
    end

    min(base_confidence + ar_bonus + area_bonus, 90)
  end

  defp calculate_color_confidence(component, gray_image) do
    # Check if the region is predominantly bright
    roi = Image.crop!(gray_image, component.bbox)
    mean_value = Image.mean!(roi)

    if mean_value > 180 do
      calculate_edge_confidence(component) * 0.8
    else
      30.0
    end
  end

  defp calculate_text_confidence(contour) do
    calculate_edge_confidence(contour) * 0.9
  end

  defp extract_roi(image, {x, y, w, h}) do
    Image.crop!(image, x, y, w, h)
  end

  defp score_ocr_result(text, confidence) do
    text_score = cond do
      PlateValidator.valid?(text) -> 100
      String.length(text) == 7 -> 70
      String.length(text) >= 6 && String.length(text) <= 8 -> 50
      true -> 10
    end

    text_score * confidence / 100
  end

  defp combine_confidences(detection_conf, ocr_conf) do
    # Weighted average of confidences
    (detection_conf * 0.4 + ocr_conf * 0.6)
  end

  defp calculate_area({_x, _y, w, h}) do
    w * h
  end

  defp calculate_aspect_ratio({_x, _y, w, h}) do
    w / h
  end

  defp remove_duplicates(candidates) do
    candidates
    |> Enum.reduce([], fn candidate, acc ->
      if Enum.any?(acc, fn existing ->
        overlaps?(candidate.bbox, existing.bbox, 0.5)
      end) do
        acc
      else
        [candidate | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp overlaps?(bbox1, bbox2, threshold) do
    iou = calculate_iou(bbox1, bbox2)
    iou > threshold
  end

  defp calculate_iou({x1, y1, w1, h1}, {x2, y2, w2, h2}) do
    # Intersection over Union
    x1_min = x1
    y1_min = y1
    x1_max = x1 + w1
    y1_max = y1 + h1

    x2_min = x2
    y2_min = y2
    x2_max = x2 + w2
    y2_max = y2 + h2

    inter_x_min = max(x1_min, x2_min)
    inter_y_min = max(y1_min, y2_min)
    inter_x_max = min(x1_max, x2_max)
    inter_y_max = min(y1_max, y2_max)

    if inter_x_max > inter_x_min && inter_y_max > inter_y_min do
      inter_area = (inter_x_max - inter_x_min) * (inter_y_max - inter_y_min)
      area1 = w1 * h1
      area2 = w2 * h2
      union_area = area1 + area2 - inter_area

      inter_area / union_area
    else
      0.0
    end
  end
end
