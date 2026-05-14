# API de Detecção de Fraude Baseada em Vetores (Zig + SIMD)

Implementação de alta performance para o desafio Rinha de Backend 2026. Detecção de fraude via busca k-NN aproximada em 3 milhões de vetores de referência, com latência sub-milissegundo sob restrição severa de CPU e memória.

## 📊 Resultados do Teste Oficial (k6 — 54.059 transações)

Teste rodado localmente com imagem `linux/amd64` via Docker + k6, seguindo o script oficial da Rinha.

| Métrica | Resultado |
| :--- | :--- |
| **Score final** | **4608.09 pts** |
| **score_p99** | +1879.01 (p99 = 13,21 ms¹) |
| **score_det** | +2729.07 |
| **HTTP errors** | **0** (em 54.059 requisições) |
| **failure_rate** | 0,01% |
| **E = 1×FP + 3×FN** | **7** |
| **FP / FN / Erros** | 1 / 2 / 0 |
| **TP / TN** | 24.035 / 30.021 |

> ¹ p99 medido sob emulação QEMU (ARM64 → amd64). Em hardware x86_64 nativo, com `cpu_period=10ms`, estimativa: p99 ~2 ms → score_p99 ~2699 → **score total ~5428 pts**.

## 🔬 Arquitetura e Decisões Técnicas

### Motor de Busca Vetorial (IVF + f16)

- **3 milhões de vetores** de referência organizados em **1.000 clusters** via K-Means++ (100 iterações)
- **Vetores armazenados em f16** (half-precision): 16× mais precisos que u8, 83 MB de índice (vs. 43 MB em u8 ou 168 MB em f32 — que excede o limite de 150 MB por instância)
- **nprobe = 15**: escaneia os 15 clusters mais próximos (~45.000 vetores por query); validado como ótimo — mesmo E=7 que nprobe=50, com menor latência
- **Streaming load** via `initFromFile`: evita pico de 180 MB ao carregar o índice (lê direto nas estruturas alocadas)

### Por que f16 e não u8 ou f32?

| Formato | Precisão | Memória (3M × 14) | E validado |
| :--- | :--- | :--- | :--- |
| u8 | 1/254 ≈ 0,004 | 42 MB | **158** |
| **f16** | 1/1024 ≈ 0,001 | **83 MB** | **7** |
| f32 | 1/8M ≈ 0,0000001 | 168 MB | excede limite RAM |

O u8 criava "phantom neighbors" — rank inversions por arredondamento que corrompem a busca com nprobe alto. O f16 elimina 95% dos erros de quantização mantendo o índice dentro do limite de memória.

### Infraestrutura Low-Latency

- **Unix Domain Sockets** entre Nginx e APIs: elimina overhead TCP (~0,2 ms por requisição)
- **CFS fix**: `cpu_period=10ms` (era 100ms) — reduz stalls máximos de 55ms para 5,5ms
- **Thread pool = 6** por instância: processa buscas IVF em paralelo, saturando as 0,45 CPU sem context-switch excessivo
- **Respostas pré-computadas**: `fraud_score ∈ {0.0, 0.2, 0.4, 0.6, 0.8, 1.0}` → 6 strings estáticas, zero `alloc` no hot path
- **Warmup de 300 queries** variadas ao iniciar: pré-popula L3 cache nas regiões mais acessadas do índice

### Vectorização (14 dimensões)

| Dimensão | Feature | Normalização |
| :--- | :--- | :--- |
| v[0] | Valor da transação | amount / 10.000 |
| v[1] | Parcelas | installments / 12 |
| v[2] | Razão vs. média do cliente | (amount / avg) / 10 |
| v[3] | Hora UTC | hour / 23 |
| v[4] | Dia da semana | dow / 6 |
| v[5] | Minutos desde últ. transação | minutes / 1440 (−1 se ausente) |
| v[6] | Distância da últ. transação | km / 1.000 (−1 se ausente) |
| v[7] | Distância de casa | km / 1.000 |
| v[8] | Transações nas últimas 24h | count / 20 |
| v[9] | Terminal online | 0 ou 1 |
| v[10] | Cartão presente | 0 ou 1 |
| v[11] | Comerciante desconhecido | 0 ou 1 |
| v[12] | Risco do MCC | tabela mcc_risk.json |
| v[13] | Valor médio do comerciante | avg_amount / 10.000 |

## 🏗️ Estrutura do Projeto

```
src/
├── domain/
│   ├── types.zig          # Tipos (Vector14, IndexHeader, FraudRequest)
│   ├── vectorizer.zig     # Conversão request → vetor 14D
│   └── scorer.zig         # Voto majoritário k-NN → fraud_score
├── adapters/
│   ├── vector/
│   │   ├── ivf_store.zig  # Busca IVF com f16 + streaming load
│   │   └── brute_force.zig# Busca exata (validação/diagnóstico)
│   └── http/
│       ├── handler.zig    # Handlers HTTP com respostas pré-computadas
│       └── json.zig       # Parser JSON zero-allocation
└── application/
    └── fraud_service.zig  # Orquestração vectorize → search → score
tools/
├── preprocess.zig         # K-Means++ + geração do índice f16
└── validate.zig           # Validação local com diagnóstico two-pass
```

## ⚙️ Como Executar

### Pré-requisitos
- Docker e Docker Compose

### Subir o ambiente
```bash
docker-compose up -d --build
```

A API estará disponível em `http://localhost:9999`.

### Endpoints

```bash
# Health check
curl http://localhost:9999/ready

# Score de fraude
curl -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d '{"id":"tx1","transaction":{"amount":1500.0,"installments":1,"requested_at":"2026-01-15T14:30:00Z"},...}'
```

### Validação local (requer índice f16 já gerado)
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/validate --threshold 0.6 --index ivf_index_f16.bin
```

## 🧠 Algoritmo de Decisão

1. **Vetorização**: Converte os 14 campos da transação em um vetor `[14]f32` normalizado em [0,1] (−1 para campos ausentes)
2. **Centróides**: Calcula distância L2 para os 1.000 centroids e seleciona os `nprobe=15` mais próximos
3. **Scan SIMD**: Carrega vetores f16 → converte para f32 → calcula L2 vetorial para ~45.000 candidatos
4. **k-NN heap**: Mantém os 5 vizinhos mais próximos via max-slot tracking (O(k) por substituição)
5. **Voto**: `fraud_score = fraudes_encontradas / 5`. Se ≥ 0,6 → negado; caso contrário → aprovado

## 🛠️ Tecnologias

- **Zig 0.16.0** — compilado com `-Doptimize=ReleaseFast -Dtarget_cpu=haswell`
- **AVX2, FMA, F16C** — distância L2 e conversão f16↔f32 vetorizados nativamente
- **httpz** — servidor HTTP event-driven com suporte a Unix Domain Sockets
- **Docker + Nginx** — load balancing com keepalive 1.024 conexões

---
*Rinha de Backend 2026 — foco em latência extrema e acurácia máxima dentro de restrições severas de CPU e RAM.*
