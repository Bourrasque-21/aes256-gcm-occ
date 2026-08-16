# AES-256-GCM 및 Rolling-Shutter OCC

이 저장소는 AES-256-GCM RTL 코어와 Rolling-Shutter OCC v3 설계, 각 설계의 검증 코드 및 결과를 정리한 자료입니다.

| 폴더 | 내용 |
|---|---|
| [AES-256-GCM Core 설계](AES256_GCM_Core/README.md) | 128비트 AXI4-Stream 기반 AES-256-GCM TX/RX RTL, 통합 테스트벤치, NIST AES-256 KAT 검증 |
| [Rolling-Shutter OCC v3 설계](Rolling_Shutter_OCC/README.md) | Basys3 두 대와 OV7670을 사용하는 Rolling-Shutter OCC v3 송수신 RTL 및 수신 도구 |
| [AES Summary](_docs/AES_GCM/AES_Summary.pdf) · [GCM Mode](_docs/AES_GCM/GCM_Mode.pdf) · [GCM Summary](_docs/AES_GCM/GCM_Summary.pdf) | AES 및 GCM 설계 요약 PDF |
| [Rolling-Shutter OCC v3 기술보고서](_docs/OCC/OCC_롤링셔터_v3_기술보고서.pdf) | Rolling-Shutter OCC v3 기술보고서 PDF |

상세한 설계 구조, 검증 결과와 트러블슈팅은 각 설계 폴더의 README에 정리되어 있습니다.
