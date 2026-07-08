#!/usr/bin/env bash

# ==============================================================================
# Cloudflare DDNS / DNS Updater Script (Curl-Safe & Bulletproof Parsing)
# ==============================================================================
# This version fixes the grep hang issue and is 100% safe to run via:
#   bash <(curl -fsSL your-url) OR bash <(wget -qO- your-url)
# ==============================================================================

set -e

# --- الألوان للمخرجات ---
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
NC='\e[0m' # No Color

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# --- 1. قراءة الـ Parameters في حال تم تمريرها ---
while getopts "t:z:d:" opt; do
    case "${opt}" in
        t) CLOUDFLARE_API_TOKEN="${OPTARG}" ;;
        z) CLOUDFLARE_ZONE_ID="${OPTARG}" ;;
        d) DOMAIN="${OPTARG}" ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
done

# --- 2. التحقق التفاعلي من المدخلات ---

# التحقق من توكن كلواد فلير
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    print_warning "Cloudflare API Token parameter (-t) is missing."
    read -s -p "Please enter your Cloudflare API Token: " input_token </dev/tty
    echo "" 
    while [ -z "$input_token" ]; do
        print_error "API Token cannot be empty!"
        read -s -p "Please enter your Cloudflare API Token: " input_token </dev/tty
        echo ""
    done
    CLOUDFLARE_API_TOKEN=$input_token
fi

# التحقق من Zone ID
if [ -z "$CLOUDFLARE_ZONE_ID" ]; then
    print_warning "Cloudflare Zone ID parameter (-z) is missing."
    read -p "Please enter your Cloudflare Zone ID: " input_zone </dev/tty
    while [ -z "$input_zone" ]; do
        print_error "Zone ID cannot be empty!"
        read -p "Please enter your Cloudflare Zone ID: " input_zone </dev/tty
    done
    CLOUDFLARE_ZONE_ID=$input_zone
fi

# التحقق من الدومين
if [ -z "$DOMAIN" ]; then
    print_warning "Domain parameter (-d) is missing."
    read -p "Please enter your Domain (e.g., app.example.com): " input_domain </dev/tty
    while [ -z "$input_domain" ]; do
        print_error "Domain cannot be empty!"
        read -p "Please enter your Domain: " input_domain </dev/tty
    done
    DOMAIN=$input_domain
fi

echo "--------------------------------------------------"
print_info "All configurations verified."
print_info "Target Domain: $DOMAIN"
echo "--------------------------------------------------"

# --- 3. جلب الآي بي العام الحالي للسيرفر ---
print_info "Fetching current server public IP..."
CURRENT_IP=$(curl -s --max-time 10 https://api.ipify.org || echo "")

if [ -z "$CURRENT_IP" ]; then
    print_error "Failed to fetch public IP from api.ipify.org. Exiting."
    exit 1
fi
print_info "Current Server IP: $CURRENT_IP"

# --- 4. جلب سجل الـ DNS الحالي من كلواد فلير ---
print_info "Fetching current DNS record from Cloudflare..."
DNS_RECORD_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$DOMAIN&type=A" \
     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
     -H "Content-Type: application/json")

if [[ "$DNS_RECORD_INFO" == *"\"success\":false"* ]]; then
    print_error "Cloudflare API returned an error. Please check your Token and Zone ID."
    echo "$DNS_RECORD_INFO"
    exit 1
fi

# استخدام sed الآمن بدلاً من grep المستهلك للمدخلات والذي يتسبب في التعليق
RECORD_ID=$(echo "$DNS_RECORD_INFO" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)
CLOUDFLARE_IP=$(echo "$DNS_RECORD_INFO" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -n1)

# --- 5. اتخاذ القرار (إنشاء أو تحديث أو تخطي) ---
if [ -z "$RECORD_ID" ]; then
    print_warning "DNS Record for $DOMAIN not found. Creating a new one..."
    
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":true}")
         
    if [[ "$RESPONSE" == *"\"success\":true"* ]]; then
        print_success "DNS record created successfully."
    else
        print_error "Failed to create DNS record."
        exit 1
    fi

elif [ "$CURRENT_IP" = "$CLOUDFLARE_IP" ]; then
    print_success "IP has not changed ($CURRENT_IP). Cloudflare is already up to date."

else
    print_info "IP changed from $CLOUDFLARE_IP to $CURRENT_IP. Updating Cloudflare..."
    
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$RECORD_ID" \
         -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":true}")
         
    if [[ "$RESPONSE" == *"\"success\":true"* ]]; then
        print_success "Cloudflare DNS updated successfully."
    else
        print_error "Failed to update DNS record."
        exit 1
    fi
fi 