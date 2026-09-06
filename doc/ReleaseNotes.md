<!--
SPDX-FileCopyrightText: 2026 TSUKUMO Akito <tsukumoakito99@duck.com>
SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-circuit-mesh-Commercial
-->

# v1.0.7: Netlink Barrier & Hybrid Tunnel Stability

We are pleased to announce the release of **circuit-mesh v1.0.7**.
This version marks the stabilization of our core Netlink engine and the integration of a multi-layer DNS tunneling strategy designed for hardened network environments.

> **Note:** This release (v1.0.7) focuses on the "Ground Truth" of network egress. It ensures that system network access is physically restricted to trusted entry points through direct kernel manipulation.

## 🚀 Strategic Milestone: Zero-Trust Enforcement

`circuit-mesh` is no longer just a proxy wrapper; it has evolved into a dedicated network gatekeeper. By manipulating the Linux kernel's `IPSet` via raw Netlink sockets, v1.0.7 effectively locks down the system egress, permitting only verified Tor Directory Authorities and Guard nodes.

## ✨ Key Features of circuit-mesh

- **Netlink Engine v1**: High-performance, direct kernel communication for IPSet management (IPv4/IPv6). No external `ipset` binary dependencies for the core logic.
- **Hybrid DNS Tunnels**:
  - **Native DoT**: Ultra-lightweight Zig TLS implementation for standard operations.
  - **H2-Backed DoH**: OpenSSL-powered HTTP/2 tunneling for resilient bootstrapping and fallback scenarios.
- **Circuit Mastery**: Deep integration with Tor's `ControlPort`, enabling precise `CLOSECIRCUIT` commands and SOCKS identity rotation with success-driven logic.
- **Identity Jitter**: Automated credential rotation using non-linear TTL calculation to mitigate traffic pattern analysis.

## 🛠 Technical Environment: Zig 0.15.2

To ensure the highest level of stability for our Netlink and TLS components, this release is pinned to **Zig 0.15.2**. While a roadmap to 0.16.0 exists, 0.15.2 provides the necessary predictability for our memory-tracking allocators and POSIX socket wrappers.

## 📦 Installation

For Arch Linux users, `circuit-mesh` is available via **AUR**:

```bash
yay -S circuit-mesh
```

For other distributions, use the provided **Makefile**:

```bash
make build && sudo make install
```

## 🛡 License Note

Unlike our companion project `zind`, `circuit-mesh` remains under a **dual-license** model (**AGPL-3.0-or-later** and **Commercial License**) to ensure the integrity of the security-sensitive networking code while supporting corporate integration.

---

**circuit-mesh v1.0.7 リリースのお知らせ**

本バージョンは、コアとなる Netlink エンジンの安定化と、要塞化されたネットワーク環境向けに設計された多層 DNS トンネリング戦略の統合を実現した重要なリリースです。

> **補足:** v1.0.7 は、ネットワーク出口通信の「唯一の真実（Ground Truth）」に焦点を当てています。カーネルへの直接操作を通じて、システムのアクセスを信頼されたエントリポイントのみに物理的に制限します。

## 🚀 戦略的マイルストーン：ゼロトラストの強制

`circuit-mesh` は単なるプロキシ・ラッパーから、専用のネットワーク・ゲートキーパーへと進化しました。生の Netlink ソケットを介して Linux カーネルの `IPSet` を操作することで、検証済みの Tor ディレクトリオーソリティおよびガードノードのみを許可し、システムの出口通信を効果的にロックダウンします。

## ✨ circuit-mesh の主な特徴

- **Netlink エンジン v1**: IPv4/IPv6 対応の高性能なカーネル直接通信による IPSet 管理。コアロジックにおいて外部の `ipset` バイナリに依存しません。
- **ハイブリッド DNS トンネル**:
  - **Native DoT**: 通常運用向けの Zig ネイティブ TLS による超軽量実装。
  - **H2-Backed DoH**: ブートストラップおよびフォールバック用の、OpenSSL を活用した HTTP/2 トンネリング。
- **回路制御の極致**: Tor `ControlPort` との深い統合により、精緻な `CLOSECIRCUIT` コマンドの発行と、成功駆動型ロジックに基づく SOCKS アイデンティティ回転を実現。
- **アイデンティティ・ジッター**: 非線形な TTL 算出を用いた自動認証情報回転により、トラフィックパターンの解析を困難にします。

## 🛠 技術環境：Zig 0.15.2

Netlink および TLS コンポーネントの最大限の安定性を確保するため、本リリースは **Zig 0.15.2** に固定されています。0.16.0 への移行もロードマップに含まれていますが、現時点ではメモリトラッキング・アロケータと POSIX ソケット・ラッパーの予測可能性を優先しています。

## 📦 インストール

Arch Linux ユーザーの方は、**AUR** から導入可能です：

```bash
yay -S circuit-mesh
```

その他のディストリビューションでは、付属の **Makefile** を使用してください：

```bash
make build && sudo make install
```
