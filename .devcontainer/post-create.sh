#!/bin/bash
# Post-create script for DevContainer

echo "🚀 Running post-create setup..."

# Create necessary directories
mkdir -p priv/models
mkdir -p logs
mkdir -p src

# Create placeholder for OpenCV helper if it doesn't exist
if [ ! -f src/opencv_capture.cpp ]; then
    echo "📝 Creating OpenCV helper source..."
    cat > src/opencv_capture.cpp << 'EOF'
#include <opencv2/opencv.hpp>
#include <iostream>
#include <vector>
#include <cstdint>

// Simple OpenCV capture helper for Elixir Port communication
void send_frame(const cv::Mat& frame) {
    std::vector<uchar> buffer;
    cv::imencode(".jpg", frame, buffer);
    
    // Send 4-byte length prefix (big-endian)
    uint32_t length = buffer.size();
    uint8_t len_bytes[4] = {
        (uint8_t)((length >> 24) & 0xFF),
        (uint8_t)((length >> 16) & 0xFF),
        (uint8_t)((length >> 8) & 0xFF),
        (uint8_t)(length & 0xFF)
    };
    
    std::cout.write((char*)len_bytes, 4);
    std::cout.write((char*)buffer.data(), buffer.size());
    std::cout.flush();
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "Usage: opencv_capture <device> <fps>" << std::endl;
        return 1;
    }
    
    int device = std::stoi(argv[1]);
    int fps = std::stoi(argv[2]);
    
    cv::VideoCapture cap(device);
    if (!cap.isOpened()) {
        std::cerr << "Error: Cannot open camera " << device << std::endl;
        return 1;
    }
    
    // Set camera properties
    cap.set(cv::CAP_PROP_FRAME_WIDTH, 1920);
    cap.set(cv::CAP_PROP_FRAME_HEIGHT, 1080);
    cap.set(cv::CAP_PROP_FPS, fps);
    
    cv::Mat frame;
    std::string command;
    
    while (true) {
        // Read command from stdin
        std::getline(std::cin, command);
        
        if (command == "capture") {
            cap >> frame;
            if (!frame.empty()) {
                send_frame(frame);
            }
        } else if (command == "quit") {
            break;
        }
    }
    
    cap.release();
    return 0;
}
EOF
fi

# Compile OpenCV helper if source exists
if [ -f src/opencv_capture.cpp ]; then
    echo "🔨 Compiling OpenCV helper..."
    if g++ -o priv/opencv_capture src/opencv_capture.cpp $(pkg-config --cflags --libs opencv4) -std=c++11 2>/dev/null; then
        chmod +x priv/opencv_capture
        echo "✅ OpenCV helper compiled successfully"
    else
        echo "⚠️  OpenCV helper compilation failed (camera support will be limited)"
    fi
fi

# Create gitkeep files
touch priv/models/.gitkeep
touch logs/.gitkeep

# Download a sample YOLO model if needed (commented out by default)
# echo "📥 Downloading YOLO model..."
# wget -q -O priv/models/yolov8n.onnx https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.onnx

echo "✅ Post-create setup completed!"
echo ""
echo "🎯 Quick Start:"
echo "  1. Run 'mix deps.get' to install dependencies"
echo "  2. Run 'mix test' to verify setup"
echo "  3. Run 'plate' to start the CLI"
echo ""
echo "📚 For more help, type 'help-plate'"