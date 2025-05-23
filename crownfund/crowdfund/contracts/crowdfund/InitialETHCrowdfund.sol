// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import { ETHCrowdfundBase } from "./ETHCrowdfundBase.sol";
import { ProposalStorage } from "../proposals/ProposalStorage.sol";
import { LibAddress } from "../utils/LibAddress.sol";
import { LibRawResult } from "../utils/LibRawResult.sol";
import { LibSafeCast } from "../utils/LibSafeCast.sol";
import { Party, PartyGovernance } from "../party/Party.sol";
import { Crowdfund } from "../crowdfund/Crowdfund.sol";
import { MetadataProvider } from "../renderers/MetadataProvider.sol";
import { IGateKeeper } from "../gatekeepers/IGateKeeper.sol";
import { IGlobals } from "../globals/IGlobals.sol";
import { IERC721 } from "../tokens/IERC721.sol";

/// @notice A crowdfund for raising the initial funds for new parties.
///         Unlike other crowdfunds that are started for the purpose of
///         acquiring NFT(s), this crowdfund simply bootstraps a party with
///         funds and lets its members coordinate on what to do with it after.
contract InitialETHCrowdfund is ETHCrowdfundBase {
    using LibRawResult for bytes;
    using LibSafeCast for uint256;
    using LibAddress for address payable;

    // Options to be passed into `initialize()` when the crowdfund is created.
    struct InitialETHCrowdfundOptions {
        address payable initialContributor;
        address initialDelegate;
        uint96 minContribution;
        uint96 maxContribution;
        bool disableContributingForExistingCard;
        uint96 minTotalContributions;
        uint96 maxTotalContributions;
        uint160 exchangeRate;
        uint16 fundingSplitBps;
        address payable fundingSplitRecipient;
        uint40 duration;
        IGateKeeper gateKeeper;
        bytes12 gateKeeperId;
    }

    struct ETHPartyOptions {
        // Name of the party.
        string name;
        // Symbol of the party.
        string symbol;
        // The ID of the customization preset to use for the party card.
        uint256 customizationPresetId;
        // Options to initialize party governance with.
        Crowdfund.FixedGovernanceOpts governanceOpts;
        // Options to initialize party proposal engine with.
        ProposalStorage.ProposalEngineOpts proposalEngineOpts;
        // The tokens that are considered precious by the party.These are
        // protected assets and are subject to extra restrictions in proposals
        // vs other assets.
        IERC721[] preciousTokens;
        // The IDs associated with each token in `preciousTokens`.
        uint256[] preciousTokenIds;
        // The timestamp until which ragequit is enabled.
        uint40 rageQuitTimestamp;
        // Initial authorities to set on the party
        address[] authorities;
    }

    struct BatchContributeArgs {
        // IDs of cards to credit the contributions to. When set to 0, it means
        // a new one should be minted.
        uint256[] tokenIds;
        // The address to which voting power will be delegated for all
        // contributions. This will be ignored if recipient has already set a
        // delegate.
        address initialDelegate;
        // The contribution amounts in wei. The length of this array must be
        // equal to the length of `tokenIds`.
        uint96[] values;
        // The data required to be validated by the `gatekeeper`, if set. If no
        // `gatekeeper` is set, this can be empty.
        bytes[] gateDatas;
    }

    struct BatchContributeForArgs {
        // IDs of cards to credit the contributions to. When set to 0, it means
        // a new one should be minted.
        uint256[] tokenIds;
        // Addresses of to credit the contributions under. Each contribution
        // amount in `values` corresponds to a recipient in this array.
        address payable[] recipients;
        // The delegate to set for each recipient. This will be ignored if
        // recipient has already set a delegate.
        address[] initialDelegates;
        // The contribution amounts in wei. The length of this array must be
        // equal to the length of `recipients`.
        uint96[] values;
        // The data required to be validated by the `gatekeeper`, if set. If no
        // `gatekeeper` is set, this can be empty.
        bytes[] gateDatas;
    }

    error TokenAlreadyBatchRefundWhenLost();

    event Refunded(address indexed contributor, uint256 indexed tokenId, uint256 amount);
    event RefundError(address indexed contributor, uint256 indexed tokenId, string reason);

    /// @notice The latest id of tokens that have been minted.
    uint256 public latestTokenId;
    /// @notice When crowdfunding fails, has the batch refund been completed.
    bool public isBatchRefundOfLost;

    // Set the `Globals` contract.
    constructor(IGlobals globals) ETHCrowdfundBase(globals) {}

    /// @notice Initializer to be called prior to using the contract.
    /// @param crowdfundOpts Options to initialize the crowdfund with.
    /// @param partyOpts Options to initialize the party with.
    /// @param customMetadataProvider Optional provider to use for the party for
    ///                               rendering custom metadata.
    /// @param customMetadata Optional custom metadata to use for the party.
    function initialize(
        InitialETHCrowdfundOptions memory crowdfundOpts,
        ETHPartyOptions memory partyOpts,
        MetadataProvider customMetadataProvider,
        bytes memory customMetadata
    ) public payable onlyInitialize {
        // Create party the initial crowdfund will be for.
        Party party_ = _createParty(partyOpts, customMetadataProvider, customMetadata);

        // Initialize the crowdfund.
        _initialize(
            ETHCrowdfundOptions({
                party: party_,
                initialContributor: crowdfundOpts.initialContributor,
                initialDelegate: crowdfundOpts.initialDelegate,
                minContribution: crowdfundOpts.minContribution,
                maxContribution: crowdfundOpts.maxContribution,
                disableContributingForExistingCard: crowdfundOpts
                    .disableContributingForExistingCard,
                minTotalContributions: crowdfundOpts.minTotalContributions,
                maxTotalContributions: crowdfundOpts.maxTotalContributions,
                exchangeRate: crowdfundOpts.exchangeRate,
                fundingSplitBps: crowdfundOpts.fundingSplitBps,
                fundingSplitRecipient: crowdfundOpts.fundingSplitRecipient,
                duration: crowdfundOpts.duration,
                gateKeeper: crowdfundOpts.gateKeeper,
                gateKeeperId: crowdfundOpts.gateKeeperId
            })
        );

        // If the creator passed in some ETH during initialization, credit them
        // for the initial contribution.
        uint96 initialContribution = msg.value.safeCastUint256ToUint96();
        if (initialContribution > 0) {
            _contribute(
                crowdfundOpts.initialContributor,
                crowdfundOpts.initialDelegate,
                initialContribution,
                0,
                ""
            );
        }

        // Set up gatekeeper after initial contribution (initial always gets in).
        gateKeeper = crowdfundOpts.gateKeeper;
        gateKeeperId = crowdfundOpts.gateKeeperId;
    }

    /// @notice Contribute ETH to this crowdfund.
    /// @param initialDelegate The address to which voting power will be delegated to
    ///                        during the governance phase. This will be ignored
    ///                        if recipient has already set a delegate.
    /// @param gateData Data to pass to the gatekeeper to prove eligibility.
    /// @return votingPower The voting power the contributor receives for their
    ///                     contribution.
    function contribute(
        address initialDelegate,
        bytes memory gateData
    ) public payable onlyDelegateCall returns (uint96 votingPower) {
        return
            _contribute(
                payable(msg.sender),
                initialDelegate,
                msg.value.safeCastUint256ToUint96(),
                0, // Mint a new party card for the contributor.
                gateData
            );
    }

    /// @notice Contribute ETH to this crowdfund.
    /// @param tokenId The ID of the card the contribution is being made towards.
    /// @param initialDelegate The address to which voting power will be delegated to
    ///                        during the governance phase. This will be ignored
    ///                        if recipient has already set a delegate.
    /// @param gateData Data to pass to the gatekeeper to prove eligibility.
    /// @return votingPower The voting power the contributor receives for their
    ///                     contribution.
    function contribute(
        uint256 tokenId,
        address initialDelegate,
        bytes memory gateData
    ) public payable onlyDelegateCall returns (uint96 votingPower) {
        return
            _contribute(
                payable(msg.sender),
                initialDelegate,
                msg.value.safeCastUint256ToUint96(),
                tokenId,
                gateData
            );
    }

    /// @notice `contribute()` in batch form.
    ///         May not revert if any individual contribution fails.
    /// @param args The arguments to pass to each `contribute()` call.
    /// @return votingPowers The voting power received for each contribution.
    function batchContribute(
        BatchContributeArgs calldata args
    ) external payable onlyDelegateCall returns (uint96[] memory votingPowers) {
        uint256 numContributions = args.tokenIds.length;

        if (numContributions != args.values.length || numContributions != args.gateDatas.length) {
            revert ArityMismatch();
        }

        votingPowers = new uint96[](numContributions);
        uint256 valuesSum;

        for (uint256 i; i < numContributions; ++i) {
            votingPowers[i] = _contribute(
                payable(msg.sender),
                args.initialDelegate,
                args.values[i],
                args.tokenIds[i],
                args.gateDatas[i]
            );
            valuesSum += args.values[i];
        }
        if (msg.value != valuesSum) {
            revert InvalidMessageValue();
        }
    }

    /// @notice Contribute to this crowdfund on behalf of another address.
    /// @param tokenId The ID of the token to credit the contribution to, or
    ///                zero to mint a new party card for the recipient
    /// @param recipient The address to record the contribution under
    /// @param initialDelegate The address to which voting power will be delegated to
    ///                        during the governance phase. This will be ignored
    ///                        if recipient has already set a delegate.
    /// @param gateData Data to pass to the gatekeeper to prove eligibility
    /// @return votingPower The voting power received for the contribution
    function contributeFor(
        uint256 tokenId,
        address payable recipient,
        address initialDelegate,
        bytes memory gateData
    ) external payable onlyDelegateCall returns (uint96 votingPower) {
        return
            _contribute(
                recipient,
                initialDelegate,
                msg.value.safeCastUint256ToUint96(),
                tokenId,
                gateData
            );
    }

    /// @notice `contributeFor()` in batch form.
    ///         May not revert if any individual contribution fails.
    /// @param args The arguments for the batched `contributeFor()` calls.
    /// @return votingPowers The voting power received for each contribution.
    function batchContributeFor(
        BatchContributeForArgs calldata args
    ) external payable onlyDelegateCall returns (uint96[] memory votingPowers) {
        uint256 numContributions = args.tokenIds.length;

        if (
            numContributions != args.values.length ||
            numContributions != args.gateDatas.length ||
            numContributions != args.recipients.length
        ) {
            revert ArityMismatch();
        }

        votingPowers = new uint96[](numContributions);
        uint256 valuesSum;

        for (uint256 i; i < numContributions; ++i) {
            votingPowers[i] = _contribute(
                args.recipients[i],
                args.initialDelegates[i],
                args.values[i],
                args.tokenIds[i],
                args.gateDatas[i]
            );
            valuesSum += args.values[i];
        }
        if (msg.value != valuesSum) {
            revert InvalidMessageValue();
        }
    }

    function _contribute(
        address payable contributor,
        address delegate,
        uint96 amount,
        uint256 tokenId,
        bytes memory gateData
    ) private returns (uint96 votingPower) {
        // Require a non-null delegate.
        if (delegate == address(0)) {
            revert InvalidDelegateError();
        }

        // Must not be blocked by gatekeeper.
        IGateKeeper _gateKeeper = gateKeeper;
        if (_gateKeeper != IGateKeeper(address(0))) {
            // Checking msg.sender here instead of contributor is intentional to
            // allow someone who's allowed by a gatekeeper to invite others
            // into the Party. For example, to allow another contract, and
            // only that contract, to process contributions on behalf of
            // contributors.
            if (!_gateKeeper.isAllowed(msg.sender, gateKeeperId, gateData)) {
                revert NotAllowedByGateKeeperError(msg.sender, _gateKeeper, gateKeeperId, gateData);
            }
        }

        votingPower = _processContribution(contributor, delegate, amount);

        // OK to contribute with zero just to update delegate.
        if (amount == 0) return 0;

        if (tokenId == 0) {
            // Mint contributor a new party card.
            latestTokenId = party.mint(contributor, votingPower, delegate);
        } else if (disableContributingForExistingCard) {
            revert ContributingForExistingCardDisabledError();
        } else if (party.ownerOf(tokenId) == contributor) {
            // Increase voting power of contributor's existing party card.
            party.increaseVotingPower(tokenId, votingPower);
        } else {
            revert NotOwnerError(tokenId);
        }
    }

    /// @notice Refund the owner of a party card and burn it. Only available if
    ///         the crowdfund lost. Can be called to refund for self or on
    ///         another's behalf.
    /// @param tokenId The ID of the party card to refund the owner of then burn.
    /// @return amount The amount of ETH refunded to the contributor.
    function refund(uint256 tokenId) external returns (uint96 amount) {
        // Check crowdfund lifecycle.
        {
            CrowdfundLifecycle lc = getCrowdfundLifecycle();
            if (lc != CrowdfundLifecycle.Lost) {
                revert WrongLifecycleError(lc);
            }
        }

        // Get amount to refund.
        uint96 votingPower = party.votingPowerByTokenId(tokenId).safeCastUint256ToUint96();
        amount = convertVotingPowerToContribution(votingPower);

        if (amount > 0) {
            // Get contributor to refund.
            address payable contributor = payable(party.ownerOf(tokenId));

            // Burn contributor's party card.
            party.burn(tokenId);

            // Refund contributor.
            contributor.transferEth(amount);

            emit Refunded(contributor, tokenId, amount);
        }
    }

    /// @notice Refund the owner of a party card and burn it. Only available if
    ///         the crowdfund lost. Can be called to refund for self or on
    ///         another's behalf.
    /// @param contributor The contributor address.
    /// @return amount The amount of ETH refunded to the contributor.
    function refundOf(address contributor) external returns (uint96 amount) {
        // Check crowdfund lifecycle.
        {
            CrowdfundLifecycle lc = getCrowdfundLifecycle();
            if (lc != CrowdfundLifecycle.Lost) {
                revert WrongLifecycleError(lc);
            }
        }

        uint96 totalAmount = 0;
        for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
            try party.ownerOf(tokenId) returns (address owner) {
                if (owner == contributor) {
                    try this.refund(tokenId) returns (uint96 refundAmount) {
                        totalAmount += refundAmount;
                    } catch {
                        emit RefundError(contributor, tokenId, "Refund failed");
                    }
                }
            } catch {
                emit RefundError(contributor, tokenId, "Not owner");
            }
        }

        return totalAmount;
    }

    function batchRefundOfLost() public {
        if (isBatchRefundOfLost) {
            revert TokenAlreadyBatchRefundWhenLost();
        }

        CrowdfundLifecycle lc = getCrowdfundLifecycle();
        if (lc == CrowdfundLifecycle.Lost) {
            uint256[] memory tokenIds = new uint256[](1);
            for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
                address owner = party.ownerOf(tokenId);
                if (owner != address(0)) {
                    tokenIds[tokenId - 1] = tokenId;
                }
            }
            batchRefund(tokenIds, false);
            isBatchRefundOfLost = true;
        }
    }

    /// @notice `refund()` in batch form.
    ///         May not revert if any individual refund fails.
    /// @param tokenIds The IDs of the party cards to burn and refund the owners of.
    /// @param revertOnFailure If true, revert if any refund fails.
    /// @return amounts The amounts of ETH refunded for each refund.
    function batchRefund(
        uint256[] memory tokenIds,
        bool revertOnFailure
    ) public returns (uint96[] memory amounts) {
        uint256 numRefunds = tokenIds.length;
        amounts = new uint96[](numRefunds);

        for (uint256 i; i < numRefunds; ++i) {
            (bool s, bytes memory r) = address(this).call(
                abi.encodeCall(this.refund, (tokenIds[i]))
            );

            if (!s) {
                if (revertOnFailure) {
                    r.rawRevert();
                }
            } else {
                amounts[i] = abi.decode(r, (uint96));
            }
        }
    }

    function _createParty(
        ETHPartyOptions memory opts,
        MetadataProvider customMetadataProvider,
        bytes memory customMetadata
    ) private returns (Party) {
        uint256 authoritiesLength = opts.authorities.length + 1;
        address[] memory authorities = new address[](authoritiesLength);
        for (uint i = 0; i < authoritiesLength - 1; ++i) {
            authorities[i] = opts.authorities[i];
        }
        authorities[authoritiesLength - 1] = address(this);

        if (address(customMetadataProvider) == address(0)) {
            return
                opts.governanceOpts.partyFactory.createParty(
                    opts.governanceOpts.partyImpl,
                    authorities,
                    Party.PartyOptions({
                        name: opts.name,
                        symbol: opts.symbol,
                        customizationPresetId: opts.customizationPresetId,
                        governance: PartyGovernance.GovernanceOpts({
                            hosts: opts.governanceOpts.hosts,
                            voteDuration: opts.governanceOpts.voteDuration,
                            executionDelay: opts.governanceOpts.executionDelay,
                            passThresholdBps: opts.governanceOpts.passThresholdBps,
                            totalVotingPower: 0,
                            feeBps: opts.governanceOpts.feeBps,
                            feeRecipient: opts.governanceOpts.feeRecipient
                        }),
                        proposalEngine: opts.proposalEngineOpts
                    }),
                    opts.preciousTokens,
                    opts.preciousTokenIds,
                    opts.rageQuitTimestamp
                );
        } else {
            return
                opts.governanceOpts.partyFactory.createPartyWithMetadata(
                    opts.governanceOpts.partyImpl,
                    authorities,
                    Party.PartyOptions({
                        name: opts.name,
                        symbol: opts.symbol,
                        customizationPresetId: opts.customizationPresetId,
                        governance: PartyGovernance.GovernanceOpts({
                            hosts: opts.governanceOpts.hosts,
                            voteDuration: opts.governanceOpts.voteDuration,
                            executionDelay: opts.governanceOpts.executionDelay,
                            passThresholdBps: opts.governanceOpts.passThresholdBps,
                            totalVotingPower: 0,
                            feeBps: opts.governanceOpts.feeBps,
                            feeRecipient: opts.governanceOpts.feeRecipient
                        }),
                        proposalEngine: opts.proposalEngineOpts
                    }),
                    opts.preciousTokens,
                    opts.preciousTokenIds,
                    opts.rageQuitTimestamp,
                    customMetadataProvider,
                    customMetadata
                );
        }
    }
}
