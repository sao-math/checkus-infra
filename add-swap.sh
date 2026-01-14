#!/bin/bash

# CheckUS EC2 t2.micro Swap 메모리 추가 스크립트
# 목적: 1GB Swap 추가하여 메모리 부족 시 완충 역할

set -e

echo "======================================"
echo "CheckUS EC2 Swap 메모리 추가"
echo "======================================"

# 1. 기존 Swap 확인
echo "현재 Swap 상태:"
free -h
swapon --show

# 2. Swap 파일 생성 여부 확인
if [ -f /swapfile ]; then
    echo "⚠️  /swapfile이 이미 존재합니다. 건너뜁니다."
else
    echo "1GB Swap 파일 생성 중..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress

    echo "Swap 파일 권한 설정..."
    sudo chmod 600 /swapfile

    echo "Swap 영역 설정..."
    sudo mkswap /swapfile

    echo "Swap 활성화..."
    sudo swapon /swapfile
fi

# 3. /etc/fstab에 영구 설정 추가 (재부팅 후에도 유지)
if grep -q "/swapfile" /etc/fstab; then
    echo "✅ /etc/fstab에 이미 설정되어 있습니다."
else
    echo "재부팅 후에도 Swap 유지되도록 /etc/fstab에 추가..."
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# 4. Swap 사용 정책 최적화 (swappiness 낮추기)
# swappiness: 0~100 (낮을수록 물리 메모리 우선 사용, 기본값 60)
# t2.micro는 10으로 설정 (메모리 부족 시에만 Swap 사용)
echo "Swap 사용 정책 최적화 (swappiness=10)..."
sudo sysctl vm.swappiness=10

# 영구 설정
if grep -q "vm.swappiness" /etc/sysctl.conf; then
    echo "✅ /etc/sysctl.conf에 이미 설정되어 있습니다."
else
    echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
fi

# 5. 최종 확인
echo ""
echo "======================================"
echo "✅ Swap 추가 완료!"
echo "======================================"
free -h
swapon --show
echo ""
echo "메모리 사용 모니터링: free -h"
echo "Docker 컨테이너 상태: docker stats"
