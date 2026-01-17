#!/bin/bash

# RouteDNS Stack Management Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_usage() {
    echo "Usage: ./manage.sh [command]"
    echo ""
    echo "Commands:"
    echo "  status        - Show service status"
    echo "  logs [service] - Show service logs (haproxy, routedns, valkey)"
    echo "  restart [service] - Restart a service or all services"
    echo "  test          - Run health checks on all services"
    echo "  shell [service] - Open shell in a service container"
    echo "  help          - Show this help message"
    exit 1
}

show_status() {
    echo -e "${BLUE}📊 Service Status:${NC}"
    docker compose ps
}

show_logs() {
    service=$1
    if [ -z "$service" ]; then
        echo -e "${BLUE}📋 All Service Logs:${NC}"
        docker compose logs -f
    else
        echo -e "${BLUE}📋 Logs for $service:${NC}"
        docker compose logs -f "$service"
    fi
}

restart_service() {
    service=$1
    if [ -z "$service" ]; then
        echo -e "${YELLOW}⏳ Restarting all services...${NC}"
        docker compose restart
    else
        echo -e "${YELLOW}⏳ Restarting $service...${NC}"
        docker compose restart "$service"
    fi
    echo -e "${GREEN}✅ Done!${NC}"
}

run_health_checks() {
    echo -e "${BLUE}🏥 Running Health Checks:${NC}"
    echo ""
    
    # Load environment variables
    if [ -f .env ]; then
        export $(grep -v '^#' .env | xargs)
    fi
    
    echo -n "HAProxy health check... "
    if nc -z -w 3 127.0.0.1 8404 2>/dev/null; then
        echo -e "${GREEN}✅ OK${NC}"
    else
        echo -e "${RED}❌ FAILED${NC}"
    fi
    
    echo -n "RouteDNS health check... "
    if nc -z -w 3 127.0.0.1 5301 2>/dev/null; then
        echo -e "${GREEN}✅ OK${NC}"
    else
        echo -e "${RED}❌ FAILED${NC}"
    fi
    
    echo -n "Valkey health check... "
    if docker exec valkey valkey-cli -a "${VALKEY_PASSWORD:-changeme_in_production}" ping 2>/dev/null | grep -q PONG; then
        echo -e "${GREEN}✅ OK${NC}"
    else
        echo -e "${RED}❌ FAILED${NC}"
    fi
}

shell_service() {
    service=$1
    if [ -z "$service" ]; then
        echo "Please specify a service: haproxy, routedns, or valkey"
        exit 1
    fi
    echo -e "${BLUE}🔧 Opening shell in $service container...${NC}"
    docker compose exec "$service" /bin/sh
}

# Main script logic
if [ $# -eq 0 ]; then
    show_usage
fi

case "$1" in
    status)
        show_status
        ;;
    logs)
        show_logs "$2"
        ;;
    restart)
        restart_service "$2"
        ;;
    test)
        run_health_checks
        ;;
    shell)
        shell_service "$2"
        ;;
    help)
        show_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_usage
        ;;
esac
