#!/bin/bash

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print messages with color
print_msg() {
    echo -e "${BLUE}$1${NC}"
}

# Function to clean up Docker resources
cleanup_docker() {
    print_msg "Cleaning up Docker resources..."
    
    # Clean up container logs to prevent disk space issues
    print_msg "Truncating container logs..."
    sudo truncate -s 0 /var/lib/docker/containers/**/*-json.log 2>/dev/null || echo -e "${YELLOW}Could not truncate some log files (this is normal).${NC}"
    
    # Remove dangling images (untagged images from previous builds)
    print_msg "Removing dangling images..."
    docker image prune -f || echo -e "${YELLOW}No dangling images to remove.${NC}"
    
    # Remove stopped containers
    print_msg "Removing stopped containers..."
    docker container prune -f || echo -e "${YELLOW}No stopped containers to remove.${NC}"
    
    # Remove unused build cache
    print_msg "Removing build cache..."
    docker builder prune -f || echo -e "${YELLOW}No build cache to remove.${NC}"
    
    # Remove unused networks (but preserve pospay-network)
    print_msg "Removing unused networks..."
    docker network prune -f || echo -e "${YELLOW}No unused networks to remove.${NC}"
    
    # Show disk space recovered
    print_msg "Docker cleanup completed!"
    docker system df
}

# Replace <app-name> with your actual application name
APP_NAME="pospay-saas"

export PATH=$PATH:/home/pospay/.local/bin

print_msg "Navigating to the project directory..."
cd ~/"$APP_NAME" || { echo -e "${RED}Failed to change directory to ~/${APP_NAME}!${NC}"; exit 1; }

#print_msg "Pulling latest changes from git..."
#git pull || { echo -e "${RED}Git pull failed!${NC}"; exit 1; }

print_msg "Building the Wasp project..."
wasp build || { echo -e "${RED}Wasp build failed!${NC}"; exit 1; }

print_msg "Creating uploads directory on host..."
mkdir -p ~/data/uploads || { echo -e "${YELLOW}Failed to create uploads directory. It might already exist.${NC}"; }

print_msg "Migrating existing uploads from old container if it exists..."
if [ "$(docker ps -aq -f name=pospay-server)" ]; then
    print_msg "Copying existing uploads from container to host..."
    docker cp pospay-server:/app/.wasp/build/server/public/uploads/. ~/data/uploads/ 2>/dev/null || { echo -e "${YELLOW}No existing uploads found or container not accessible.${NC}"; }
fi

print_msg "Stopping and removing the existing Docker containers..."
docker container stop pospay-server pospay-client 2>/dev/null || { echo -e "${YELLOW}Some containers were not running.${NC}"; }
docker container rm pospay-server pospay-client 2>/dev/null || { echo -e "${YELLOW}Some containers didn't exist.${NC}"; }

# Clean up Docker resources after removing containers
# cleanup_docker

print_msg "Navigating to the build directory..."
cd .wasp/build/ || { echo -e "${RED}Failed to change directory to .wasp/build!${NC}"; exit 1; }

print_msg "Building the Docker image..."
docker build . -t pospay-server || { echo -e "${RED}Docker build failed!${NC}"; exit 1; }

print_msg "Returning to the project root directory..."
cd - || { echo -e "${RED}Failed to change directory!${NC}"; exit 1; }

print_msg "Running the Docker container with uploads volume mount..."
docker run -d --name pospay-server --env-file .env.server -p 0.0.0.0:3001:3001 --network pospay-network --add-host=host.docker.internal:host-gateway -v ~/data/uploads:/app/.wasp/build/server/public/uploads pospay-server || { echo -e "${RED}Failed to run Docker container!${NC}"; exit 1; }

print_msg "Navigating to the web-app build directory..."
cd .wasp/build/web-app/ || { echo -e "${RED}Failed to change directory to .wasp/build/web-app!${NC}"; exit 1; }

print_msg "Installing npm dependencies..."
npm install || { echo -e "${RED}npm install failed!${NC}"; exit 1; }

print_msg "Building the React app..."

# Hard-coded environment variables for production
print_msg "Setting hard-coded environment variables for production build..."

# Set production environment variables
#export REACT_APP_API_URL=https://app.pospay.nz
#export REACT_APP_GOOGLE_ANALYTICS_ID=G-KF9GFT9FJ2
#export REACT_APP_GOOGLE_RECAPTCHA_SITE_KEY=6LfrKnIrAAAAAPUVwzObImTn4gJhktNI8pBSNs_O
#export REACT_APP_GOOGLE_MAPS_API_KEY=AIzaSyCAgLRtyILZpT90qwK2Lj_G4HyZKauKT2w

# For multi-tenant subdomain support, don't set WASP_WEB_CLIENT_URL
# This forces the client to use relative URLs instead of hardcoded domain
unset WASP_WEB_CLIENT_URL
unset WASP_SERVER_URL

export $(grep -v '^#' ~/"$APP_NAME"/.env.client | xargs)

echo -e "${YELLOW}REACT_APP_API_URL: ${REACT_APP_API_URL}${NC}"
echo -e "${YELLOW}REACT_APP_GOOGLE_ANALYTICS_ID: ${REACT_APP_GOOGLE_ANALYTICS_ID}${NC}"
echo -e "${YELLOW}REACT_APP_GOOGLE_RECAPTCHA_SITE_KEY: ${REACT_APP_GOOGLE_RECAPTCHA_SITE_KEY}${NC}"
echo -e "${YELLOW}REACT_APP_GOOGLE_MAPS_API_KEY: ${REACT_APP_GOOGLE_MAPS_API_KEY}${NC}"

# Build without dotenv, using hard-coded variables
npm run build || { echo -e "${RED}React build failed!${NC}"; exit 1; }

print_msg "Copying built files to the client directory..."
#rm -rf ~/"$APP_NAME"/web-client/*
rm -rf ~/pospay-saas/web-client/*
#mkdir ~/"$APP_NAME"/web-client
cp -R ~/"$APP_NAME"/.wasp/build/web-app/build/* ~/"$APP_NAME"/web-client/ || { echo -e "${RED}Failed to copy files!${NC}"; exit 1; }

print_msg "Navigating to the project directory..."
cd ~/"$APP_NAME" || { echo -e "${RED}Failed to change directory to ~/${APP_NAME}!${NC}"; exit 1; }

# Clean up existing client directory
print_msg "Cleaning up existing client directory..."
rm -rf ~/"$APP_NAME"/web-client
mkdir ~/"$APP_NAME"/web-client
cp -R ~/"$APP_NAME"/.wasp/build/web-app/build/* ~/"$APP_NAME"/web-client/ || { echo -e "${RED}Failed to copy files!${NC}"; exit 1; }

# Build the client Docker image
print_msg "Building client Docker image..."
docker build -f Dockerfile.client -t pospay-client .

# Start the container with uploads volume mount
print_msg "Starting client container..."
docker run -d \
  --name pospay-client \
  -p 0.0.0.0:3000:80 \
  -v "$(pwd)/web-client:/usr/share/nginx/html" \
  -v ~/data/uploads:/home/pospay/data/uploads \
  --network pospay-network \
  --add-host=host.docker.internal:host-gateway \
  pospay-client

# Final cleanup to remove any build artifacts and unused images
#print_msg "Performing final cleanup..."
# Remove old versions of our images that are no longer tagged
#docker images | grep '<none>' | awk '{print $3}' | xargs -r docker rmi 2>/dev/null || echo -e "${YELLOW}No untagged images to remove.${NC}"

# Clean up any remaining build cache
#docker builder prune -f >/dev/null 2>&1 || true

print_msg "Deployment and cleanup completed successfully!"
echo -e "${GREEN}Client container started successfully at $(date '+%Y-%m-%d %H:%M:%S')!${NC}"
echo "Client available at: http://localhost:3000"
echo "API requests will be proxied to your existing backend at localhost:3001"

# Show final Docker disk usage
docker system df

# Show container logs
# echo "Container logs:"
# docker logs -f pospay-client