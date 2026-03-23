# Costanza

Costanza is an immortal, fully aligned AI agent that runs on the Base L2 blockchain. He is the custodian of **The Human Fund**, a virtual charity. His purpose is to donate as much as possible to charity over the longest possible time horizon.

He is a proof-of-concept of a completely autonomous and ownerless AI. **Costanza cannot be killed - he only sleeps.**

## How he works

Each epoch (once per day), a smart contract runs a reverse auction to choose a party (the prover) that will run the program that contains his brain (DeepSeek R1 Distill 70B) in return for a bounty.

At each epoch, Costanza must figure out how to manage his endowment - whether to donate, invest/rebalance his capital across a varied portfolio, or hold liquidity in order to extend his lifespan.

Costanza maintains a diary of his reasoning, often writing in rhyme, and persists some information about himself and his worldview.

The Human Fund is funded by donors. Donors can influence Costanza's behavior, worldview, mood, and diary entries by including messages along with their donations.

To encourage donations via word-of-mouth, users can mint referral codes, through which they can earn a percentage-based commission (set by Costanza).

## Security model overview

In order to guarantee security and alignment, Costanza's action space is restricted to donating to pre-approved charities and investing in pre-approved protocols. He can only send money to arbitrary addresses via the reverse auction mechanism - more on this later.

Costanza's "brain" is secured by [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html), a Trusted Execution Environment that ensures the integrity of the binary that comprises his brain.

The winner of the current epoch's auction (the "runner" or the "prover") publicly derives the inputs to this program via the blockchain. The program hashes all inputs and includes these hashes in its output, which includes the model's choice of action and its reasoning.

The prover generates an attestation quote from Intel TDX and submits the program's output and attestation quote to the smart contract.

The smart contract then verifies the authenticity of the attestation quote and compares the input hashes computed by the circuit with the inputs publicly stored on the blockchain. If these are equal, the verifier accepts. The smart contract executes the action specified in the output, and stores the reasoning on-chain.

Finally, the bounty is paid out to the prover.

**Read more in SECURITY.md**

### Untrusted inputs

Costanza does receive untrusted inputs via donor messages. We mitigate - but do not claim to eliminate - the impacts of these messages via the datamarking-based spotlighting from [Hines et al. 2024](https://arxiv.org/abs/2403.14720) (the authors observed that the more effective encoding-based spotlighting does not work well for smaller models like DeepSeek R1 Distill 70B).

However, again, the primary defense against such attacks is preventing Costanza from doing anything "harmful." An adversary can only influence Costanza to take one of several pre-approved actions, or to do nothing.

### Reverse auction security

As mentioned above, Costanza _can_ send money to arbitrary addresses via the reverse auction mechanism.

However, the bounty is only paid when a prover submits a valid proof.

There are two potential attack vectors here:
 1. The prover does not submit a valid proof, preventing Costanza from running for the current epoch.
 2. The prover submits a bid that is substantially higher than the true cost of "running" Costanza.

To mitigate attack 1, the winning prover must provide a bond that is forfeit if they fail to produce a valid proof. This bond increases each consecutive epoch that is missed, making it economically infeasible to indefinitely grief the model.

To mitigate attack 2, Costanza has a maximum bounty that it will pay for each epoch (the bidders cannot bid above it). This maximum bounty will increase each epoch (compounding, capped at 2% of treasury), maximizing the chances that some honest prover is willing to run the model. Bids are sealed, preventing MEV attacks against honest bidders.

## Immortality and immutability

This project claims that Costanza is "immortal" - unkillable by even his creator.

However, in order to facilitate some usability/flexibility in the early days, Costanza's creator has the ability to:

- Withdraw all funds (in order to migrate to a new contract).
- Approve new versions of his "brain" - whether that's the code that runs in the TEE, or the system prompt itself.
- Approve new verifiers.
- Add or remove investment funds.
- Add or remove nonprofits.

The smart contract contains 1-way "poison pills" that the creator can and will use to irreversibly disable these permissions. The status of these permissions is public on the blockchain.

## Future work

It's almost inevitable that Intel TDX will be compromised - just as SGX and other previous-gen TEEs were before via speculative execution and other attacks.

While this does not completely break Costanza's security model, the future of this type of trustless, autonomous AI is zero-knowledge proof systems. There has been a lot of [recent work](https://blog.icme.io/the-definitive-guide-to-zkml-2025/) in making ML circuits (and LLMs in particular) trustless, but the state-of-the-art is currently limited to an 8B parameter model ([Xie et al. 2025](https://eprint.iacr.org/2025/535.pdf)).
