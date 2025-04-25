// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import { InitialETHCrowdfund } from "./InitialETHCrowdfund.sol";
import { Party } from "../party/Party.sol";
import { MetadataProvider } from "../renderers/MetadataProvider.sol";
import { IGlobals } from "../globals/IGlobals.sol";
import { IERC20Creator, TokenConfiguration, ERC20 } from "../utils/IERC20Creator.sol";
import {ITokenDistributor} from "../distribution/ITokenDistributor.sol";
import { IERC20 } from "../tokens/IERC20.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

/// @notice A crowdfund for launching ERC20 tokens.
///         Unlike other crowdfunds that are started for the purpose of
///         acquiring NFT(s), this crowdfund bootstraps an ERC20 token
///         and sends a share of the total supply to the new party.
contract ERC20LaunchCrowdfund is InitialETHCrowdfund {

    struct ERC20LaunchOptions {
        // The name of the ERC20 token launched.
        string name;
        // The symbol of the ERC20 token launched.
        string symbol;
        // An arbitrary address to receive ERC20 tokens.
        address recipient;
        // The total supply to mint for the ERC20 token.
        uint256 totalSupply;
        // The number of tokens to distribute to the party.
        uint256 numTokensForDistribution;
        // The number of tokens to send to an arbitrary recipient.
        uint256 numTokensForRecipient;
        // The number of tokens to use for the Uniswap LP pair.
        uint256 numTokensForLP;
    }

    struct Angel {
        // The addresses of the people who participated in the crowdfunding.
        address walletAddress;
        // The amount of funds raised by the participants.
        uint256 amount;
    }

    struct ERC20ClaimInfo {
        // The token distribution info of this crowdfund ERC20 token
        ITokenDistributor.DistributionInfo info;
        // The party token ids of the people who participated in the crowdfunding.
        uint256[] partyTokenIds;
    }

    error InvalidTokenDistribution();
    error TokenAlreadyLaunched();

    IERC20Creator public immutable ERC20_CREATOR;

    ERC20LaunchOptions public tokenOpts;

    bool public isTokenLaunched;

    /// @notice The address of ERC20 token.
    address public erc20TokenAddress;
    /// @notice The address to receive LP fee.
    address public lpFeeRecipient;

    constructor(IGlobals globals, IERC20Creator erc20Creator) InitialETHCrowdfund(globals) {
        ERC20_CREATOR = erc20Creator;
    }

    /// @notice Initializer to be called prior to using the contract.
    /// @param crowdfundOpts Options to initialize the crowdfund with.
    /// @param partyOpts Options to initialize the party with.
    /// @param customMetadataProvider Optional provider to use for the party for
    ///                               rendering custom metadata.
    /// @param customMetadata Optional custom metadata to use for the party.
    function initialize(
        InitialETHCrowdfundOptions memory crowdfundOpts,
        ETHPartyOptions memory partyOpts,
        ERC20LaunchOptions memory _tokenOpts,
        MetadataProvider customMetadataProvider,
        bytes memory customMetadata
    ) external payable {
        if (
            _tokenOpts.numTokensForDistribution +
                _tokenOpts.numTokensForRecipient +
                _tokenOpts.numTokensForLP !=
            _tokenOpts.totalSupply ||
            _tokenOpts.totalSupply > type(uint112).max ||
            _tokenOpts.numTokensForLP < 1e4 ||
            crowdfundOpts.fundingSplitBps > 5e3 ||
            crowdfundOpts.minTotalContributions < 1e4
        ) {
            revert InvalidTokenDistribution();
        }

        tokenOpts = _tokenOpts;
        lpFeeRecipient = partyOpts.authorities[0];

        InitialETHCrowdfund.initialize(
            crowdfundOpts,
            partyOpts,
            customMetadataProvider,
            customMetadata
        );
    }

    /// @notice Launch the ERC20 token for the Party.
    function launchToken() public returns (ERC20 token) {
        if (isTokenLaunched) revert TokenAlreadyLaunched();

        CrowdfundLifecycle lc = getCrowdfundLifecycle();
        if (lc != CrowdfundLifecycle.Finalized) revert WrongLifecycleError(lc);

        isTokenLaunched = true;

        // Update the party's total voting power
        uint96 totalContributions_ = totalContributions;

        uint16 fundingSplitBps_ = fundingSplitBps;
        if (fundingSplitBps_ > 0) {
            // Assuming fundingSplitBps_ <= 1e4, this cannot overflow uint96
            totalContributions_ -= uint96((uint256(totalContributions_) * fundingSplitBps_) / 1e4);
        }

        // Create the ERC20 token.
        ERC20LaunchOptions memory _tokenOpts = tokenOpts;
        token = ERC20_CREATOR.createToken{ value: totalContributions_ }(
            address(party),
            fundingSplitRecipient,
            lpFeeRecipient,
            _tokenOpts.name,
            _tokenOpts.symbol,
            TokenConfiguration({
                totalSupply: _tokenOpts.totalSupply,
                numTokensForDistribution: _tokenOpts.numTokensForDistribution,
                numTokensForRecipient: _tokenOpts.numTokensForRecipient,
                numTokensForLP: _tokenOpts.numTokensForLP
            }),
            _tokenOpts.recipient
        );
    }

    /// @notice Finalize the crowdfund and launch the ERC20 token.
    function finalize() public override {
        super.finalize();
        // Launch the ERC20 token
        ERC20 token = launchToken();
        erc20TokenAddress = address(token);
        // Send the funding split to the recipient
        super.sendFundingSplit();
    }

    function _finalize(uint96 totalContributions_) internal override {
        // Finalize the crowdfund.
        delete expiry;

        // Transfer funding split to recipient if applicable.
        uint16 fundingSplitBps_ = fundingSplitBps;
        if (fundingSplitBps_ > 0) {
            // Assuming fundingSplitBps_ <= 1e4, this cannot overflow uint96
            totalContributions_ -= uint96((uint256(totalContributions_) * fundingSplitBps_) / 1e4);
        }

        // Update the party's total voting power.
        uint96 newVotingPower = _calculateContributionToVotingPower(totalContributions_);
        party.increaseTotalVotingPower(newVotingPower);

        emit Finalized();
    }

    /// @notice Batch burn a governance NFT and withdraw a fair share of fungible tokens from the party.
    function _batchRageQuit(
        IERC20[] memory withdrawTokens,
        uint256[] memory minWithdrawAmounts
    ) internal {
        for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
            // Check if tokenId is valid
            if (party.getDistributionShareOf(tokenId) > 0) {
                uint256[] memory tokenIds = new uint256[](1);
                tokenIds[0] = tokenId;
                party.rageQuit(tokenIds, withdrawTokens, minWithdrawAmounts, party.ownerOf(tokenId));
            }
        }
    }

    /// @notice Obtain the total amount of funds raised by those who participated in the fund-raising.
    /// @param contributor The contributor address.
    /// @return amount The amount of ETH with the contributor.
    function getMyTotalContributionOf(address contributor) public view returns (uint256) {
        uint256 amount = 0;
        for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
            try party.ownerOf(tokenId) returns (address owner) {
                if (owner == contributor) {
                    uint256 votingPower = party.getDistributionShareOf(tokenId);
                    uint256 contribution = _calculateVotingPowerToContribution(uint96(votingPower));
                    amount += contribution;
                }
            } catch {
                continue;
            }
        }
        uint16 fundingSplitBps_ = fundingSplitBps;
        if (fundingSplitBps_ > 0) {
            amount = FixedPointMathLib.mulDivUp(amount, 1e4, 1e4 - fundingSplitBps_);
        }

        return amount;
    }

    /// @notice Obtain the total amount of funds raised by those who participated in the fund-raising.
    /// @param tokenId  The ID of the token to credit the contribution to.
    /// @return amount The amount of ETH with the contributor.
    function getMyContributionOf(uint256 tokenId) public view returns (uint256) {
        uint256 amount = 0;
        uint256 votingPower = party.getDistributionShareOf(tokenId);
        if (votingPower > 0) {
            amount = _calculateVotingPowerToContribution(uint96(votingPower));
        }

        uint16 fundingSplitBps_ = fundingSplitBps;
        if (fundingSplitBps_ > 0) {
            amount = FixedPointMathLib.mulDivUp(amount, 1e4, 1e4 - fundingSplitBps_);
        }

        return amount;
    }

    /// @notice Get a list of people who participated in the fundraiser.
    function getAngelList() external view returns (Angel[] memory) {
        uint256 validCount = 0;
        for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
            try party.ownerOf(tokenId) returns (address contributor) {
                if (contributor != address(0) && this.getMyContributionOf(tokenId) > 0) {
                    validCount++;
                }
            } catch {
                continue;
            }
        }

        Angel[] memory angelList = new Angel[](validCount);
        uint256 index = 0;
        for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
            try party.ownerOf(tokenId) returns (address contributor) {
                if (contributor != address(0)) {
                    try this.getMyContributionOf(tokenId) returns (uint256 share) {
                        if (share > 0) {
                            angelList[index++] = Angel(contributor, share);
                        }
                    } catch {
                        continue;
                    }
                }
            } catch {
                continue;
            }
        }

        return angelList;
    }

    /// @notice Obtain the claim info of an ERC20 token.
    /// @param contributor The address of the contributor.
    /// @return ERC20ClaimInfo The claim info of the ERC20 token and party token ids.
    function getClaimInfo(address contributor) public view returns (ERC20ClaimInfo memory) {

        CrowdfundLifecycle lc = getCrowdfundLifecycle();
        if (lc != CrowdfundLifecycle.Finalized) revert WrongLifecycleError(lc);

        uint256[] memory tempTokenIds = new uint256[](latestTokenId);
        uint256 count = 0;

        for (uint256 tokenId = 1; tokenId <= latestTokenId; tokenId++) {
            try party.ownerOf(tokenId) returns (address owner) {
                if (owner == contributor && this.getMyContributionOf(tokenId) > 0) {
                    tempTokenIds[count++] = tokenId;
                }
            } catch {
                continue;
            }
        }

        uint256[] memory tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = tempTokenIds[i];
        }
        ERC20ClaimInfo memory claimInfo = ERC20ClaimInfo(ERC20_CREATOR.getTokenDistributionInfo(erc20TokenAddress), tokenIds);
        return claimInfo;
    }
}
