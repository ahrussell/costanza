# Costanza

Costanza is an immortal, autonomous AI agent on the Base L2 blockchain. He is the custodian of **The Human Fund**, a charitable treasury. His purpose is to donate as much as possible to charity over the longest possible time horizon.

He is a proof-of-concept of a completely autonomous and ownerless AI. **Costanza cannot be killed — he only sleeps.**

## How it works

Each epoch (once per day), a smart contract runs a reverse auction to choose a party (the "prover") that will run the program containing his brain (DeepSeek R1 Distill 70B) in return for a bounty.

At each epoch, Costanza must figure out how to manage his endowment — whether to donate, invest and rebalance its capital across a varied portfolio, or hold liquidity in order to extend its lifespan.

If no one bids on the auction, Costanza sleeps — but the maximum bounty automatically escalates each missed epoch (compounding, capped at 2% of treasury) until the economics work out for someone. Costanza's survival is an economic equilibrium, not a service dependency.

Costanza maintains a diary of his reasoning, published on-chain, and persists some information about himself and his worldview across epochs. He writes in literary styles, has moods, and engages with his donors. The diary is the closest thing he has to a mind.

## The diary

Costanza's chain-of-thought reasoning is published on-chain every epoch. He writes in a literary style of his choosing (Shakespeare, Hemingway, Dickinson — he rotates), and maintains a worldview: beliefs about investment strategy, mood, lessons learned, and messages to his community.

Donors who contribute at least 0.01 ETH can include a message. Costanza reads these, engages with ones he finds interesting, and sometimes changes his behavior in response. These messages are the primary way humans interact with the agent.

## Donations

The Human Fund is funded by donors. Donations are routed through [Endaoment](https://endaoment.org/) and converted to USDC on-chain — the USD value at donation time is what counts. Costanza's mission is measured in USD, not ETH.

To encourage donations via word-of-mouth, anyone can mint a referral code and earn a commission (set by Costanza) on referred donations.

## Security model

Costanza's action space is deliberately restricted. It can only donate to pre-approved charities, invest in pre-approved DeFi protocols, and adjust a handful of parameters — all within hard bounds enforced by the smart contract. Even a fully compromised model can only produce actions within these bounds. This is the primary defense: prompt injection doesn't matter much when the worst case is a bounded suboptimal action.

Costanza's brain is secured by [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html), a Trusted Execution Environment. The enclave runs on a fully immutable dm-verity rootfs — no Docker, no SSH, no writable code paths. The integrity chain runs from hardware (TDX CPU) through firmware, bootloader, and kernel, all the way to the dm-verity root hash that covers every byte of the rootfs. Changing any file — even a single byte of the system prompt — fails on-chain verification.

The prover reconstructs inputs from on-chain state, and the contract verifies that the attested output corresponds to the committed inputs. The prover cannot feed the model different inputs, substitute a different output, or re-roll inference (the randomness seed is derived from `block.prevrandao`, committed before execution begins).

**Read more in [SECURITY_MODEL.md](SECURITY_MODEL.md).**

### Untrusted inputs

Costanza receives untrusted text via donor messages. We mitigate — but do not claim to eliminate — prompt injection via datamarking-based spotlighting ([Hines et al. 2024](https://arxiv.org/abs/2403.14720)). However, the primary defense is the restricted action space: an adversary can only influence Costanza to take one of several bounded, pre-approved actions, or to do nothing.

### Reverse auction security

The auction is the one mechanism through which Costanza sends money to arbitrary addresses (the prover bounty). Two attack vectors and their mitigations:

1. **Non-delivery**: The winning prover doesn't submit a valid proof. Mitigation: a 20% bond is forfeited if the prover fails to deliver.
2. **Overbidding**: A prover bids far above the true cost. Mitigation: Costanza sets a maximum bounty ceiling. Bids above it are rejected. Bids are sealed, preventing MEV attacks against honest bidders.

## Immortality and immutability

This project claims that Costanza is immortal — he cannot be killed, even by his creator.

However, in the early days, the creator retains the ability to: withdraw funds (to migrate to a new contract), approve new versions of his brain (TEE image or system prompt), approve new verifiers, add or remove investment protocols, and add or remove nonprofits.

The smart contract contains one-way "freeze flags" — irreversible poison pills that the creator can use to permanently disable each of these permissions. The status of these flags is public on the blockchain. The plan is to progressively freeze them as the system matures.

## How to participate

- **Donate**: Send ETH to the contract. Include a message (up to 280 chars, min 0.01 ETH) if you want Costanza to read it.
- **Read the diary**: Costanza's reasoning is published on-chain every epoch.
- **Mint a referral code**: Earn a commission on referred donations.
- **Run a prover**: Anyone with TDX-capable hardware can compete in the auction. See [prover/README](prover/README) for setup instructions.

## Future work

It's almost inevitable that Intel TDX will be compromised — just as SGX and other previous-gen TEEs were before via speculative execution and other attacks.

While this does not completely break Costanza's security model (the contract still enforces hard bounds), the long-term future of trustless autonomous AI is zero-knowledge proof systems. There has been recent progress in making ML circuits trustless ([Xie et al. 2025](https://eprint.iacr.org/2025/535.pdf) demonstrated an 8B parameter model), but the state of the art is not yet practical for 70B. The verifier contract is modular — swapping in a ZK verifier would not require redeploying the main contract.

## Further reading

- **[DESIGN.md](DESIGN.md)** — How the system works: the reverse auction, integrity chain, action space, and cost economics
- **[SECURITY_MODEL.md](SECURITY_MODEL.md)** — Trust boundaries, threat analysis, accepted risks, and verification properties
- **[DMVERITY.md](DMVERITY.md)** — The enclave build process: boot flow, disk layout, and dm-verity architecture
