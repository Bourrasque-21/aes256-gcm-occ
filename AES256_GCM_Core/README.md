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

## 전체 설계 구조

TX와 RX는 각각 AES-256 코어 하나와 GHASH 코어 하나를 사용합니다. TX의
ciphertext와 RX에 수신된 ciphertext는 인증 대상인 GHASH 입력으로 들어가며,
RX에서 복원된 plaintext는 TAG 판정이 끝날 때까지 별도 buffer에 격리됩니다.

```text
                              ┌───────────────┐
Plaintext ──> AES-CTR XOR ──> │  Ciphertext   │ ──> TX output
                 │            └───────┬───────┘
                 │                    │
Key, IV ──> AES-256 core              └──> GHASH ──> TAG

Ciphertext ──┬──> AES-CTR XOR ──> 미인증 Plaintext ──> Packet Buffer ──> 인증 출력
             │                                             ▲
             └──> GHASH ──> Calculated TAG ──> 비교 ───────┘
                                           Received TAG
```

| 모듈 | 역할 | 주요 내부 구조 |
|---|---|---|
| `gcm_tx_engine` | plaintext 암호화 및 TAG 생성 | AES-CTR와 ciphertext GHASH의 중첩 스케줄링 |
| `gcm_rx_engine` | ciphertext 복호화 및 TAG 판정 | AES-CTR와 ciphertext GHASH 병렬 실행, 미인증 평문 출력 |
| `aes256_core` | 128비트 AES-256 블록 암호화 | 반복형 14-round datapath, 라운드 키 cache 및 prefetch |
| `ghash_engine_seq` | `Y_next=(Y XOR X)·H` 계산 제어 | 8비트 순차 GF 곱셈기 구동 |
| `gf128_mult_8bit_seq` | GF(2^128) 곱셈 | 매 클럭 8비트 처리, 16단계 입력 shift |
| `authenticated_packet_buffer` | 인증 전 평문 임시 보관 | block RAM 추론 배열, 인증 성공 후에만 순차 출력 |

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

### 처리 형식

| 항목 | 현재 RTL 형식 |
|---|---|
| AES key | 256비트 |
| IV | 96비트 |
| AAD | 128비트 1블록 |
| Payload | `cmd_payload_blocks`개의 128비트 full block |
| TAG | 128비트 |
| 첫 payload counter | `{cmd_iv, 32'd2}` |
| 길이 블록 | `{64'd128, cmd_payload_blocks × 128}` |

부분 블록과 가변 길이 AAD는 현재 인터페이스에 포함하지 않습니다. TX와 RX는
명령에서 받은 payload 블록 수를 기준으로 마지막 블록과 GCM 길이 블록을 계산합니다.

### `valid/ready` 동작

| 전송 | 성립 조건 | 동작 |
|---|---|---|
| 명령 입력 | `cmd_valid && cmd_ready` | key, IV, AAD, payload 길이를 내부 register에 저장 |
| TX 평문 입력 | `plaintext_valid && plaintext_ready` | 한 블록을 받아 현재 keystream과 XOR |
| RX 암호문 입력 | `ciphertext_valid && ciphertext_ready` | 한 블록을 AES-CTR 및 GHASH 처리 대상으로 저장 |
| TX 결과 출력 | `ciphertext_valid && ciphertext_ready` | ciphertext 전달 후 현재 블록의 GHASH 시작 |
| TAG 출력 | `tag_valid && tag_ready` | TX message 종료 |
| 인증 결과 | `auth_valid && auth_ready` | RX message 종료 |

출력 측 `ready`가 내려가면 엔진은 해당 출력 상태와 데이터를 유지합니다. `busy`는
명령을 수락한 시점부터 전체 message 처리가 끝날 때까지 유지되며, `abort`는 진행
중인 message를 취소하고 내부 AES/GHASH 연산이 정리된 뒤 idle 상태로 복귀시킵니다.

### RX 신뢰 경계

`gcm_rx_engine`의 `plaintext_data/plaintext_valid`는 TAG 검증 전에 발생하는
**미인증 평문**입니다. `authenticated_packet_buffer`는 이 평문을 한 message
분량 저장하고 `auth_valid && auth_ok` 이후에만 packet stream으로 출력합니다.
인증 실패 시 저장된 평문은 외부로 내보내지 않습니다.

이 buffer는 AXI에 의존하지 않는 generic `valid/ready` 모듈이며 기본 크기는
80블록입니다. 다른 buffer를 사용하는 상위 시스템도 같은 인증 경계를 지켜야 합니다.

buffer의 `PAYLOAD_BLOCKS` 값은 해당 RX message의 `cmd_payload_blocks`와 같아야
합니다. `packet_start_valid`에서 session/frame/packet 메타데이터를 함께 저장하고,
평문 블록을 모두 받은 뒤 다음과 같이 분기합니다.

```text
B_IDLE -> B_WRITE -> B_WAIT_AUTH
                           ├─ auth_ok=1 -> B_READ_PREP -> B_READ -> packet_complete
                           └─ auth_ok=0 -> B_IDLE (외부 출력 없음)
```

## GCM 연산 흐름

96비트 IV를 사용하므로 초기 counter와 첫 payload counter는 다음과 같습니다.

```text
H       = AES_K(0^128)
J0      = IV || 0x00000001
CTR_i   = IV || (i + 2)                 (i = 0, 1, ...)
S0      = AES_K(J0)
C_i     = P_i XOR AES_K(CTR_i)
Y_AAD   = (0^128 XOR AAD) · H
Y_i+1   = (Y_i XOR C_i) · H
LEN     = 64'd128 || (payload_blocks × 128)
TAG     = S0 XOR ((Y_last XOR LEN) · H)
```

GHASH에는 TX/RX 모두 ciphertext가 입력됩니다. 따라서 RX는 plaintext 복원과
인증값 누적을 동시에 실행할 수 있고, 마지막에는 수신 TAG와 계산 TAG를 128비트
전체 비교하여 `auth_ok`를 결정합니다.

### TX 상태 진행

```text
IDLE
  -> H 계산 또는 동일 key의 H 재사용
  -> J0 암호화 + AAD GHASH
  -> 첫 CTR keystream 사전 계산
  -> 평문 입력 및 ciphertext 출력
  -> 현재 ciphertext GHASH + 다음 CTR keystream 계산 (반복)
  -> LEN GHASH
  -> TAG 출력
```

첫 블록의 keystream을 미리 계산해 둔 뒤, ciphertext 한 블록이 출력될 때마다
현재 ciphertext의 GHASH와 다음 counter의 AES 암호화를 동시에 시작합니다. 마지막
블록에서는 다음 keystream이 필요 없으므로 GHASH 완료 후 바로 LEN 처리로 이동합니다.

### RX 상태 진행

```text
IDLE
  -> H 계산 또는 동일 key의 H 재사용
  -> J0 암호화 + AAD GHASH
  -> ciphertext 입력
  -> 현재 counter AES 암호화 + ciphertext GHASH
  -> 미인증 plaintext 출력 (반복)
  -> LEN GHASH
  -> 수신 TAG 대기 및 비교
  -> auth_valid/auth_ok 출력
```

RX 엔진은 ciphertext를 받은 뒤 같은 블록에 대해 AES-CTR과 GHASH를 동시에
시작합니다. 두 연산의 `done` 시점은 독립 register에 저장하며, 양쪽이 모두
완료된 뒤에만 plaintext 출력과 다음 블록 처리를 진행합니다.

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

AES round datapath는 14라운드, GF 곱셈기의 `M_RUN` 구간은 16클럭입니다. 두
연산을 중첩하므로 순차 실행 시 약 30클럭이던 산술 구간은 더 긴 GHASH 연산이
지배합니다. 실제 블록 간격에는 입출력 handshake와 FSM 전이 클럭이 추가됩니다.

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

## 검증 항목 및 결과

최신 standalone 코어는 GCM TX/RX 통합 동작과 AES-256 블록 암호 코어를
각각 검증합니다. GCM 테스트는 인증 전 평문과 인증 후 출력의 신뢰 경계까지
검사하며, AES KAT는 NIST AESAVS 벡터 전체를 비교합니다.

### GCM TX/RX 엔진

```powershell
.\AES256_GCM_Core\sim\run_gcm_engine_test.ps1
```

[`tb_gcm_engines.sv`](tb/tb_gcm_engines.sv)의 검증 항목은 다음과 같습니다.

| 구분 | 검증 항목 | 합격 조건 |
|---|---|---|
| TX 암호문 | 독립 기준값과 ciphertext 4블록 비교 | 4블록 모두 일치 |
| TX 인증값 | 128비트 authentication TAG 기준값 비교 | TAG 완전 일치 |
| RX 복호화 | TX 결과를 RX에 입력해 plaintext round trip 비교 | 원본 4블록 및 `plaintext_last` 일치 |
| 정상 인증 | 정상 TAG 입력 | `auth_valid=1`, `auth_ok=1` |
| 변조 탐지 | TAG 최하위 1비트 변조 | `auth_valid=1`, `auth_ok=0` |
| 평문 격리 | 인증 성공/실패 packet의 quarantine buffer 출력 검사 | 성공 packet만 4블록 출력, 실패 packet은 0블록 출력 |
| 완료 조건 | 출력 블록 수와 인증 결과 수 검사 | raw 8블록, safe 4블록, pass 1회, fail 1회 |
| 정지 탐지 | 전체 테스트 timeout | 20,000클럭 이내 완료 |

합격 판정:

```text
[TB][PASS] GCM TX/RX core engine test
```

Vivado xsim 2025.2에서 위 검증 항목을 모두 통과했습니다.

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

### 검증 결과

| DUT/검증 | 시뮬레이터 | 결과 | 실행일 | 근거 |
|---|---|---:|---|---|
| 현재 GCM TX/RX 엔진 통합 검증 | Vivado xsim 2025.2 | **PASS** | 2026-08-17 | [테스트벤치](tb/tb_gcm_engines.sv) · [실행 스크립트](sim/run_gcm_engine_test.ps1) |
| 현재 `rtl/aes256_core.sv` NIST KAT | Vivado xsim 2025.2 | **405 pass, 0 fail** | 2026-08-17 | [xsim 실행 로그](verification/nist_aes256_kat/results/aes256_core_xsim_20260817.txt) |
| 기존 iterative AES-256 core NIST KAT | Synopsys VCS W-2024.09-SP1 | **405 pass, 0 fail** | 2026-08-13 | [VCS 실행 로그](verification/nist_aes256_kat/results/vcs_aes256_iterative_core_20260813.txt) |

전체 AES KAT의 합격 조건은 정확히 405개 벡터와 불일치 0개입니다. 이 KAT는
AES-256 ECB 블록 암호 코어를 검증하며 GCM 전체 표준 적합성 시험을 의미하지
않습니다.

VCS/Verdi로 수행했던 기존 AES-256 KAT 테스트벤치와 결과 화면도
`verification/nist_aes256_kat/`에 참고 자료로 보존합니다.

![VCS/Verdi NIST AES-256 KAT 통과 화면](verification/nist_aes256_kat/results/vcs_verdi_kat_pass_20260813.png)

![VCS/Verdi AES-256 파형](verification/nist_aes256_kat/results/vcs_verdi_waveform_20260813.png)

## 트러블슈팅

### AES와 GHASH 완료 펄스 불일치

AES와 GHASH를 동시에 시작해도 연산 지연이 서로 다르고 `done`은 각각 1클럭
펄스이므로 `aes_done && ghash_done`만 기다리면 상태 전이가 멈출 수 있습니다.
현재 TX/RX 엔진은 `aes_complete_reg`와 `ghash_complete_reg`에 각 완료 시점을
독립적으로 저장하고, 두 연산이 모두 끝난 뒤 다음 상태로 진행합니다.

### TAG 검증 전 평문 출력

RX는 수신 ciphertext를 GHASH에 누적하는 동안 AES-CTR 복호화도 병렬 수행하므로
TAG를 받기 전에 `plaintext_valid`가 발생합니다. 이 출력은 미인증 평문입니다.
현재 `authenticated_packet_buffer`가 한 packet을 격리하고
`auth_valid && auth_ok`일 때만 외부로 내보내며, 인증 실패 시 저장 내용을
출력하지 않습니다.

### 동일 키의 반복 확장 지연

초기 구조는 같은 세션 키를 사용하는 블록마다 AES-256 키 확장을 다시 수행해
불필요한 지연이 발생했습니다. 현재 `aes256_core.sv`는 전체 라운드 키를 저장하고
`round_keys_valid && key == key_reg`이면 확장을 건너뜁니다. GCM의 `H` 값도
키와 함께 cache하여 동일 키의 다음 message에서 재사용합니다.

### GHASH 입력 선택 경로

초기 8비트 순차 곱셈기는 `byte_index`로 128비트 입력의 현재 바이트를 선택해
합성 시 16:1 byte MUX가 생성됐습니다. 현재 곱셈기는 항상
`x_reg[127:120]`을 사용하고 매 클럭 입력 register를 8비트 이동하여, 16클럭
연산 구조를 유지하면서 가변 선택 경로를 제거했습니다.

### AES 라운드 키 선택 경로

라운드 번호로 15개의 128비트 키 중 하나를 조합 선택하면 AES round datapath에
큰 MUX가 놓입니다. 현재 구조는 다음 라운드 키를 `round_key_reg`에 미리 저장해
라운드 연산이 고정된 register 출력만 사용하도록 구성했습니다.

## 개념 정리 문서

- [AES Summary](../_docs/AES_GCM/AES_Summary.pdf)
- [GCM Mode](../_docs/AES_GCM/GCM_Mode.pdf)
- [GCM Summary](../_docs/AES_GCM/GCM_Summary.pdf)
