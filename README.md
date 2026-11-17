# Morpheus SessionRouter — provider approval not bound to the user (PoC)

Foundry fork PoC against the deployed LumerinDiamond on Base (fork pinned to block 58505524): a provider approval signed for one user is consumed by a different, unprivileged address to open a fundingAccount-paid (stipend mode) session, and the named user's own `openSession` then reverts because the approval is burned.
The test asserts the loss: the provider is paid 6.048 MOR out of the protocol fundingAccount for the attacker's session, and the fundingAccount balance drops by exactly the provider's gain.
All actors are fresh unprivileged accounts (the provider registers through the normal public flow); no privileged impersonation, and no mainnet transactions — fork simulation only.
Run (only Foundry required; the Base RPC endpoint is hardcoded in the test):

    forge test --match-contract ApprovalReplayTest -vv
