# Fish shell configuration for Plate Reader System development

# Enable vi mode
fish_vi_key_bindings

# Aliases for Elixir/Phoenix development
alias mx="mix"
alias mxc="mix compile"
alias mxd="mix deps.get"
alias mxt="mix test"
alias mxr="mix run"
alias iex="iex -S mix"
alias ies="iex -S mix phx.server"
alias mps="mix phx.server"
alias mdg="mix deps.get"
alias mdc="mix deps.compile"
alias mdu="mix deps.update --all"
alias mf="mix format"
alias mcredo="mix credo --strict"
alias mdializer="mix dialyzer"
alias mcover="mix test --cover"

# Plate Reader specific aliases
alias plate="iex -S mix run -e 'PlateReaderSystem.CLI.run()'"
alias plate-test="mix test"
alias plate-format="mix format"
alias plate-analyze="mix credo --strict && mix dialyzer"
alias plate-logs="tail -f logs/plate_detections_*.txt"
alias plate-clean="rm -rf _build deps && mix deps.get && mix compile"

# Git aliases
alias gs="git status"
alias ga="git add"
alias gc="git commit"
alias gp="git push"
alias gl="git log --oneline --graph --decorate"
alias gd="git diff"
alias gco="git checkout"
alias gb="git branch"
alias gpl="git pull"
alias gstash="git stash"
alias gpop="git stash pop"

# Docker aliases
alias dc="docker-compose"
alias dcu="docker-compose up"
alias dcd="docker-compose down"
alias dcl="docker-compose logs -f"
alias dps="docker ps"
alias dex="docker exec -it"

# Utility functions
function take
    mkdir -p $argv[1]
    cd $argv[1]
end

function serve
    python3 -m http.server $argv[1]
end

# Camera utilities
function test-camera
    echo "Testing camera devices..."
    v4l2-ctl --list-devices
end

function camera-info
    v4l2-ctl -d /dev/video0 --all
end

function capture-test
    ffmpeg -f v4l2 -i /dev/video0 -frames 1 test_capture.jpg
    echo "Test image saved as test_capture.jpg"
end

# Development helpers
function plate-watch
    echo "Starting Plate Reader System with file watching..."
    fswatch -o lib test | xargs -n1 -I{} sh -c 'clear && mix test'
end

function plate-repl
    echo "Starting Plate Reader REPL..."
    iex -S mix
end

function plate-demo
    echo "Running Plate Reader demo..."
    mix run --no-halt -e "PlateReaderSystem.CLI.run()"
end

# Environment info
function devinfo
    echo "=== Plate Reader Development Environment ==="
    echo "Elixir:" (elixir --version | head -n 1)
    echo "Erlang/OTP:" (erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell)
    echo "Mix:" (mix --version)
    echo "OpenCV:" (pkg-config --modversion opencv4 2>/dev/null || echo "Not found")
    echo "Tesseract:" (tesseract --version 2>&1 | head -n 1)
    echo "FFmpeg:" (ffmpeg -version | head -n 1)
    echo "Camera devices:"
    ls /dev/video* 2>/dev/null || echo "  No camera devices found"
    echo "========================================="
end

# Project setup check
function check-setup
    echo "Checking project setup..."
    
    # Check for required files
    set -l required_files "mix.exs" "lib/plate_reader_system.ex" "priv/models/.gitkeep"
    for file in $required_files
        if test -f $file
            echo "✓ $file exists"
        else
            echo "✗ $file missing"
        end
    end
    
    # Check for compiled OpenCV helper
    if test -f priv/opencv_capture
        echo "✓ OpenCV helper compiled"
    else
        echo "✗ OpenCV helper not compiled"
        echo "  Run: g++ -o priv/opencv_capture src/opencv_capture.cpp (pkg-config --cflags --libs opencv4)"
    end
    
    # Check deps
    if test -d deps
        echo "✓ Dependencies installed"
    else
        echo "✗ Dependencies not installed"
        echo "  Run: mix deps.get"
    end
    
    echo "Done!"
end

# Welcome message
echo "🚗 Welcome to Plate Reader System Development Container! 🚗"
echo ""
echo "Quick commands:"
echo "  plate       - Start the CLI interface"
echo "  plate-demo  - Run a demo"
echo "  plate-test  - Run tests"
echo "  devinfo     - Show environment info"
echo "  check-setup - Verify project setup"
echo ""
echo "Type 'help-plate' for more commands"

function help-plate
    echo "Plate Reader System Commands:"
    echo ""
    echo "Development:"
    echo "  plate         - Start CLI interface"
    echo "  plate-repl    - Start IEx REPL"
    echo "  plate-test    - Run tests"
    echo "  plate-watch   - Run tests on file changes"
    echo "  plate-format  - Format code"
    echo "  plate-analyze - Run code analysis"
    echo "  plate-logs    - Tail log files"
    echo "  plate-clean   - Clean and rebuild"
    echo ""
    echo "Camera:"
    echo "  test-camera   - List camera devices"
    echo "  camera-info   - Show camera details"
    echo "  capture-test  - Capture test image"
    echo ""
    echo "Utilities:"
    echo "  devinfo      - Show environment info"
    echo "  check-setup  - Verify project setup"
    echo ""
end

# Set prompt
function fish_prompt
    set_color brblue
    echo -n (basename (pwd))
    set_color normal
    echo -n ' '
    set_color yellow
    echo -n 'λ '
    set_color normal
end

# Enable auto-suggestions
set fish_autosuggestion_enabled 1

# Path additions
set -x PATH $PATH /home/vscode/.mix/escripts

# Default to the project directory
cd /workspaces/plate_reader_system 2>/dev/null