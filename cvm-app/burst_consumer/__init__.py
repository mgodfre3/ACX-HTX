"""burst_consumer package — runs inside the Azure burst CVM.

Pulls encrypted work from the ALDO edge, processes it in memory only, and
sends re-encrypted results back. Talks to Azure ONLY for platform attestation
evidence (IMDS or MAA). Never talks to Azure Storage. Never talks to Azure
Key Vault for data-key operations.
"""

__version__ = "1.0.0"
