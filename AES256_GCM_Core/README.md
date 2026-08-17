# AES-256-GCM Block-Parallel Crypto Engines

플랫폼, AXI packet adapter와 영상 프레임 제어를 제외한 standalone
AES-256-GCM 암호 연산 RTL입니다. `gcm_tx_engine`과 `gcm_rx_engine`은 명령 및
128비트 블록 단위 `valid/ready` 인터페이스를 사용하므로 AXI4-Stream, DMA,
네트워크 packetizer 등 필요한 상위 계층에 연결할 수 있습니다.

## 구성

```text
AES256_GCM_Core/
├── rtl/
│   ├── gcm_tx_engine.sv          AES-CTR 암호화, GHASH, TAG 생성
│   ├── gcm_rx_engine.sv          AES-CTR 복호화, GHASH, TAG 검증
│   ├── authenticated_packet_buffer.sv
│   │                              인증 전 평문 격리 및 성공 packet 출력
│   ├── gcm_packet_pkg.sv         GCM LEN 블록 공통 함수
│   ├── aes256_core.sv            반복형 AES-256 및 라운드 키 캐시
│   ├── aes_*.sv                  AES 라운드 연산 모듈
│   ├── ghash_engine_seq.sv       순차 GHASH 제어
│   └── gf128_mult_8bit_seq.sv    8비트/클럭 GF(2^128) 곱셈기
├── tb/
│   └── tb_gcm_engines.sv         TX/RX 코어 참조값 및 TAG 검증 TB
├── sim/
│   └── run_gcm_engine_test.ps1   Vivado xsim 실행 스크립트
└── verification/nist_aes256_kat/ NIST AESAVS AES-256 KAT
```

Vivado 프로젝트에는 package와 하위 모듈을 먼저 추가하고 다음 순서로 컴파일합니다.

```text
aes_pkg.sv
gcm_packet_pkg.sv
aes_sbox.sv
aes_subbytes.sv
aes_shiftrows.sv
aes_mixcolumns.sv
aes_addroundkey.sv
aes_round.sv
aes256_core.sv
gf128_mult_8bit_seq.sv
ghash_engine_seq.sv
gcm_tx_engine.sv
gcm_rx_engine.sv
authenticated_packet_buffer.sv
```

## 코어 인터페이스

한 명령은 하나의 GCM message를 정의합니다.

```text
cmd_key             256-bit AES key
cmd_iv               96-bit IV
cmd_aad             128-bit AAD
cmd_payload_blocks   payload의 128-bit 블록 수
```

TX는 plaintext 블록을 받아 ciphertext 블록과 128비트 TAG를 출력합니다. RX는
ciphertext 블록과 수신 TAG를 받아 plaintext 블록 및 `auth_valid/auth_ok` 결과를
출력합니다. 고정 80블록 packet은 상위 시스템에서
`cmd_payload_blocks=80`으로 지정하며, 코어 자체는 message 길이를 명령으로 받습니다.

### RX 신뢰 경계

`gcm_rx_engine`의 `plaintext_data/plaintext_valid`는 TAG 검증 전에 발생하는
**미인증 평문**입니다. `authenticated_packet_buffer`는 이 평문을 한 message
분량 저장하고 `auth_valid && auth_ok` 이후에만 packet stream으로 출력합니다.
인증 실패 시 저장된 평문은 외부로 내보내지 않습니다.

이 buffer는 AXI에 의존하지 않는 generic `valid/ready` 모듈이며 기본 크기는
80블록입니다. 다른 buffer를 사용하는 상위 시스템도 같은 인증 경계를 지켜야 합니다.

## 블록 수준 병렬 처리

AES 라운드를 전개하거나 AES 코어를 복제하지 않고, 반복형 AES-256 엔진 하나와
순차 GHASH 엔진 하나를 동시에 가동하는 macro-pipelining 구조입니다.

### TX

```text
현재 ciphertext C_i의 GHASH
                ||
다음 payload를 위한 AES-CTR keystream 생성
```

### RX

```text
Ciphertext C_i --+-- AES-CTR -> Plaintext P_i
                 +-- GHASH   -> authentication state
```

AES 연산은 약 14클럭, GHASH는 16클럭이지만 두 연산을 중첩하여 정상 payload
구간의 구조적 블록 처리 간격을 약 16클럭으로 유지합니다.

## 연산 경로 개선

### GF(2^128) 입력 시프트 구조

기존 곱셈기는 `byte_index`로 128비트 입력의 현재 바이트를 가변 선택해 합성 시
16:1 바이트 MUX가 생성됐습니다. 현재 구조는 항상 `x_reg[127:120]`만 처리하고
매 클럭 `x_reg`를 8비트 이동합니다.

- 8비트/클럭, 총 16클럭 유지
- GF(2^128) 연산 결과 및 외부 인터페이스 유지
- GHASH critical path의 가변 바이트 선택기 제거

### AES 키 스케줄과 라운드 키 경로

- 동일 key의 전체 AES-256 라운드 키를 cache하여 다음 블록에서 재사용
- 새 key의 key expansion을 capture/store 두 단계로 분리
- 다음 round key를 register에 미리 저장해 AES round datapath의 15:1,
  128비트 MUX 제거
- 초기 key expansion 지연은 증가하지만 동일 key를 사용하는 정상 GCM payload의
  블록 처리 간격에는 영향을 주지 않음

TX의 다음 블록 존재 여부와 RX의 마지막 블록 여부도 한 상태 앞에서 1비트로
등록하여 32비트 add/compare 결과가 AES enable 및 출력 제어 경로를 직접 구동하지
않도록 구성했습니다.

## 검증

### GCM TX/RX 엔진

```powershell
.\AES256_GCM_Core\sim\run_gcm_engine_test.ps1
```

테스트 항목:

- 독립 기준값과 ciphertext 4블록 비교
- 128비트 authentication TAG 기준값 비교
- TX 결과를 RX에 입력한 plaintext round trip
- 정상 TAG 승인
- TAG 1비트 변조 시 인증 거부
- 인증 성공 packet만 quarantine buffer 외부로 출력되는지 확인

합격 판정:

```text
[TB][PASS] GCM TX/RX core engine test
```

### AES-256 NIST KAT

```powershell
.\AES256_GCM_Core\verification\nist_aes256_kat\sim\run_aes_core_kat.ps1 -NoGui
```

| 벡터 파일 | 벡터 수 |
|---|---:|
| `ECBGFSbox256.rsp` | 5 |
| `ECBKeySbox256.rsp` | 16 |
| `ECBVarKey256.rsp` | 256 |
| `ECBVarTxt256.rsp` | 128 |
| 합계 | **405** |

Vivado xsim 2025.2 결과는 **405 pass, 0 fail**입니다. 이 KAT는 AES-256 ECB
블록 암호 코어를 검증하며 GCM 전체 표준 적합성 시험을 의미하지 않습니다.

VCS/Verdi로 수행했던 기존 AES-256 KAT 테스트벤치와 결과 화면도
`verification/nist_aes256_kat/`에 참고 자료로 보존합니다.

## 상위 계층에서 구현할 항목

이 폴더에는 다음 기능이 포함되지 않습니다.

- AXI4-Stream adapter 및 packet framing
- DMA/BRAM 연결과 byte-order 변환
- AAD/IV 생성 정책
- 영상 line/frame 조립 및 오류 복구 정책

따라서 실제 시스템에서는 IV 재사용 방지와 packet buffer 이후의 영상·네트워크
정책을 상위 계층에서 구현해야 합니다.

## 설계 문서

- [AES Summary](../_docs/AES_GCM/AES_Summary.pdf)
- [GCM Mode](../_docs/AES_GCM/GCM_Mode.pdf)
- [GCM Summary](../_docs/AES_GCM/GCM_Summary.pdf)
