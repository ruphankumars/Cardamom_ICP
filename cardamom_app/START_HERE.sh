#!/bin/bash

# Flutter iOS Module Error - Interactive Fix
# This script provides an interactive menu to fix module build errors

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Clear screen
clear

# Print header
echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}║                                                                          ║${NC}"
echo -e "${PURPLE}║              FLUTTER iOS MODULE ERROR - INTERACTIVE FIX                  ║${NC}"
echo -e "${PURPLE}║                                                                          ║${NC}"
echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Print errors being fixed
echo -e "${RED}❌ Errors to fix:${NC}"
echo "   • could not build module 'Test'"
echo "   • could not build module 'connectivity_plus'"
echo "   • module 'Flutter' not found"
echo ""

# Check if in Flutter project
if [ ! -f "pubspec.yaml" ]; then
    echo -e "${RED}❌ Error: Not in a Flutter project root directory${NC}"
    echo "   Please cd to your Flutter project directory and run this again."
    exit 1
fi

echo -e "${GREEN}✅ Flutter project detected${NC}"
echo ""

# Show menu
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Choose a fix option:${NC}"
echo ""
echo "  1) 🚀 Automated Fix (Recommended) - Fixes everything automatically"
echo "  2) ⚡ Quick Fix - Simple automated command sequence"
echo "  3) 📝 Replace Podfile - Use the complete fixed Podfile"
echo "  4) 🔍 Show Documentation - View available guides"
echo "  5) ❌ Exit"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "Enter your choice (1-5): " choice

case $choice in
    1)
        echo ""
        echo -e "${GREEN}🚀 Running Automated Fix...${NC}"
        echo ""
        
        if [ -f "fix_module_errors.sh" ]; then
            chmod +x fix_module_errors.sh
            ./fix_module_errors.sh
        else
            echo -e "${RED}❌ Error: fix_module_errors.sh not found${NC}"
            exit 1
        fi
        ;;
        
    2)
        echo ""
        echo -e "${GREEN}⚡ Running Quick Fix...${NC}"
        echo ""
        
        if [ -f "quick_fix.sh" ]; then
            chmod +x quick_fix.sh
            ./quick_fix.sh
        else
            echo -e "${RED}❌ Error: quick_fix.sh not found${NC}"
            exit 1
        fi
        ;;
        
    3)
        echo ""
        echo -e "${GREEN}📝 Replacing Podfile...${NC}"
        echo ""
        
        if [ ! -f "Podfile.fixed" ]; then
            echo -e "${RED}❌ Error: Podfile.fixed not found${NC}"
            exit 1
        fi
        
        if [ ! -f "ios/Podfile" ]; then
            echo -e "${RED}❌ Error: ios/Podfile not found${NC}"
            exit 1
        fi
        
        # Backup original
        echo "   Backing up original Podfile..."
        cp ios/Podfile ios/Podfile.backup
        
        # Replace
        echo "   Replacing Podfile..."
        cp Podfile.fixed ios/Podfile
        
        # Clean
        echo "   Cleaning..."
        flutter clean
        cd ios
        rm -rf Pods Podfile.lock .symlinks
        
        # Reinstall
        echo "   Installing pods..."
        pod install
        
        cd ..
        echo "   Getting Flutter dependencies..."
        flutter pub get
        
        echo ""
        echo -e "${GREEN}✅ Podfile replaced successfully!${NC}"
        echo ""
        echo "Now run: ${CYAN}flutter build ios${NC}"
        ;;
        
    4)
        echo ""
        echo -e "${CYAN}📚 Available Documentation:${NC}"
        echo ""
        echo "  📄 INDEX.md                      - Master index of all files"
        echo "  📄 IMPLEMENTATION_SUMMARY.md     - Complete overview (start here)"
        echo "  📄 FIX_MODULE_ERRORS_README.md   - Comprehensive fix guide"
        echo "  📄 TROUBLESHOOTING_CHECKLIST.md  - When fix doesn't work"
        echo "  📄 QUICK_REFERENCE.txt           - Quick visual guide"
        echo "  📄 PODFILE_PATCH.txt             - Code to add to Podfile"
        echo ""
        echo -e "${YELLOW}To read a file:${NC}"
        echo "  cat QUICK_REFERENCE.txt"
        echo "  open INDEX.md"
        echo ""
        ;;
        
    5)
        echo ""
        echo -e "${YELLOW}👋 Exiting. No changes made.${NC}"
        echo ""
        echo "To fix later, run: ./START_HERE.sh"
        exit 0
        ;;
        
    *)
        echo ""
        echo -e "${RED}❌ Invalid choice. Please run the script again.${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Fix process completed!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Verify: ${CYAN}flutter build ios${NC}"
echo "  2. Run app: ${CYAN}flutter run${NC}"
echo ""
echo "If you encounter issues, read: ${CYAN}TROUBLESHOOTING_CHECKLIST.md${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
