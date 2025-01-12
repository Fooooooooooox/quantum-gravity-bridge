// SPDX-License-Identifier: Apache-2.0

// 原来量子引力桥就只是验证了“作为rollup da层”的celestia的数据是否有效
// 这个事情本来是由celestia的节点来验证的 有了量子引力桥之后这个事情就可以由以太坊来完成
// 调用量子引力桥之后回返回true或false 来判断数据是正确还是错误的


pragma solidity ^0.8.4;

import "./lib/openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./Constants.sol";
import "./DataRootTuple.sol";
import "./IDAOracle.sol";
import "./lib/tree/binary/BinaryMerkleProof.sol";
import "./lib/tree/binary/BinaryMerkleTree.sol";

struct Validator {
    address addr;
    uint256 power;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @title Quantum Gravity Bridge: Celestia -> EVM, Data Availability relay.
/// @dev The relay relies on a set of signers to attest to some event on
/// Celestia. These signers are the Celestia validator set, who sign over every
/// Celestia block. Keeping track of the Celestia validator set is accomplished
/// by updating this contract's view of the validator set with
/// `updateValidatorSet()`. At least 2/3 of the voting power of the current
/// view of the validator set must sign off on new relayed events, submitted
/// with `submitDataRootTupleRoot()`. Each event is a batch of `DataRootTuple`s
/// (see ./DataRootTuple.sol), with each tuple representing a single data root
/// in a Celestia block header. Relayed tuples are in the same order as the
/// block headers.
contract QuantumGravityBridge is IDAOracle {
    // Don't change the order of state for working upgrades AND BE AWARE OF
    // INHERITANCE VARIABLES! Inherited contracts contain storage slots and must
    // be accounted for in any upgrades. Always test an exact upgrade on testnet
    // and localhost before mainnet upgrades.

    ////////////////
    // Immutables //
    ////////////////

    bytes32 public immutable BRIDGE_ID;

    /////////////
    // Storage //
    /////////////

    /// @notice Domain-separated commitment to the latest validator set.
    bytes32 public state_lastValidatorSetCheckpoint;
    /// @notice Voting power required to submit a new update.
    uint256 public state_powerThreshold;
    /// @notice Unique nonce of validator set updates.
    uint256 public state_lastValidatorSetNonce;
    /// @notice Unique nonce of data root tuple root updates.
    uint256 public state_lastDataRootTupleRootNonce;
    /// @notice Mapping of data root tuple root nonces to data root tuple roots.
    mapping(uint256 => bytes32) public state_dataRootTupleRoots;

    ////////////
    // Events //
    ////////////

    /// @notice Emitted when a new root of data root tuples is relayed.
    /// @param nonce Nonce.
    /// @param dataRootTupleRoot Merkle root of relayed data root tuples.
    /// See `submitDataRootTupleRoot`.
    event DataRootTupleRootEvent(uint256 indexed nonce, bytes32 dataRootTupleRoot);

    /// @notice Emitted when the validator set is updated.
    /// @param nonce Nonce.
    /// @param powerThreshold New voting power threshold.
    /// @param validatorSetHash Hash of new validator set.
    /// See `updateValidatorSet`.
    event ValidatorSetUpdatedEvent(uint256 indexed nonce, uint256 powerThreshold, bytes32 validatorSetHash);

    ////////////
    // Errors //
    ////////////

    /// @notice Malformed current validator set.
    error MalformedCurrentValidatorSet();

    /// @notice Validator signature does not match.
    error InvalidSignature();

    /// @notice Submitted validator set signatures do not have enough power.
    error InsufficientVotingPower();

    /// @notice New validator set nonce must be greater than the current nonce.
    error InvalidValidatorSetNonce();

    /// @notice Supplied current validators and powers do not match checkpoint.
    error SuppliedValidatorSetInvalid();

    /// @notice Data root tuple root nonce nonce must be greater than the current nonce.
    error InvalidDataRootTupleRootNonce();

    ///////////////
    // Functions //
    ///////////////

    /// @param _bridge_id Identifier of the bridge, used in signatures for
    /// domain separation.
    /// @param _nonce Celestia block height at which bridge is initialized.
    /// @param _powerThreshold Initial voting power that is needed to approve
    /// operations.
    /// @param _validatorSetHash Initial validator set hash. This does not need
    /// to be the genesis validator set of the bridged chain, only the initial
    /// validator set of the bridge.
    constructor(
        bytes32 _bridge_id,
        uint256 _nonce,
        uint256 _powerThreshold,
        bytes32 _validatorSetHash
    ) {
        BRIDGE_ID = _bridge_id;

        // CHECKS

        bytes32 newCheckpoint = domainSeparateValidatorSetHash(_bridge_id, _nonce, _powerThreshold, _validatorSetHash);

        // EFFECTS

        state_lastValidatorSetNonce = _nonce;
        state_lastValidatorSetCheckpoint = newCheckpoint;
        state_powerThreshold = _powerThreshold;

        // LOGS

        emit ValidatorSetUpdatedEvent(_nonce, _powerThreshold, _validatorSetHash);
    }

// 这些r. .s .v是什么？
// v is needed to recover the public key 是在恢复公钥的时候必要的参数
// 因为你通过一个签名来恢复公钥的时候 可能会返回多个valid public address
// 关于以太坊签名验证的相关知识：
// 以太坊中没有地址的概念 一个账户实际上拥有私钥和公钥 地址其实是你公钥进行hash之后的后20个bytes

// FrontierSigner 的SignatureValues 方法中，将签名结果41c4a2eb073e6df89c3f467b3516e9c313590d8d57f7c217fe7e72a7b4a6b8ed5f20a758396a5e681ce1ab4cec749f8560e28c9eb91072ec7a8acc002a11bb1d00
// 分为三份，分别是：
// 前32字节的R,41c4a2eb073e6df89c3f467b3516e9c313590d8d57f7c217fe7e72a7b4a6b8ed
// 中间32字节的S,5f20a758396a5e681ce1ab4cec749f8560e28c9eb91072ec7a8acc002a11bb1d
// 最后一个字节00加上27，得到V，十进制为27
// 



    /// @notice Utility function to check if a signature is nil.
    /// If all bytes of the 65-byte signature are zero, then it's a nil signature.
    function isSigNil(Signature calldata _sig) private pure returns (bool) {
        return (_sig.r == 0 && _sig.s == 0 && _sig.v == 0);
    }

    /// @notice Utility function to verify EIP-191 signatures.
    function verifySig(
        address _signer,
        bytes32 _digest,
        Signature calldata _sig
    ) private pure returns (bool) {
        bytes32 digest_eip191 = ECDSA.toEthSignedMessageHash(_digest);

        return _signer == ECDSA.recover(digest_eip191, _sig.v, _sig.r, _sig.s);
    }

    /// @dev Computes the hash of a validator set.
    /// @param _validators The validator set to hash.
    function computeValidatorSetHash(Validator[] calldata _validators) private pure returns (bytes32) {
        return keccak256(abi.encode(_validators));
    }

    /// @dev Make a domain-separated commitment to the validator set.
    /// A hash of all relevant information about the validator set.
    /// The format of the hash is:
    ///     keccak256(bridge_id, VALIDATOR_SET_HASH_DOMAIN_SEPARATOR, nonce, power_threshold, validator_set_hash)
    /// The elements in the validator set should be monotonically decreasing by power.
    /// @param _bridge_id Bridge ID.
    /// @param _nonce Nonce.
    /// @param _powerThreshold The voting power threshold.
    /// @param _validatorSetHash Validator set hash.
    function domainSeparateValidatorSetHash(
        bytes32 _bridge_id,
        uint256 _nonce,
        uint256 _powerThreshold,
        bytes32 _validatorSetHash
    ) private pure returns (bytes32) {
        bytes32 c = keccak256(
            abi.encode(_bridge_id, VALIDATOR_SET_HASH_DOMAIN_SEPARATOR, _nonce, _powerThreshold, _validatorSetHash)
        );

        return c;
    }

    /// @dev Make a domain-separated commitment to a data root tuple root.
    /// A hash of all relevant information about a data root tuple root.
    /// The format of the hash is:
    ///     keccak256(bridge_id, DATA_ROOT_TUPLE_ROOT_DOMAIN_SEPARATOR, oldNonce, newNonce, dataRootTupleRoot)
    /// @param _bridge_id Bridge ID.
    /// @param _oldNonce Celestia block height at which commitment begins.
    /// @param _newNonce Celestia block height at which commitment ends.
    /// @param _dataRootTupleRoot Data root tuple root.
    function domainSeparateDataRootTupleRoot(
        bytes32 _bridge_id,
        uint256 _oldNonce,
        uint256 _newNonce,
        bytes32 _dataRootTupleRoot
    ) private pure returns (bytes32) {
        bytes32 c = keccak256(
            abi.encode(_bridge_id, DATA_ROOT_TUPLE_ROOT_DOMAIN_SEPARATOR, _oldNonce, _newNonce, _dataRootTupleRoot)
        );

        return c;
    }

    /// @dev Checks that enough voting power signed over a digest.
    /// @param _currentValidators The current validators.
    /// @param _sigs The current validators' signatures.
    /// @param _digest This is what we are checking they have signed.
    /// @param _powerThreshold At least this much power must have signed.
    function checkValidatorSignatures(
        // The current validator set and their powers
        Validator[] calldata _currentValidators,
        Signature[] calldata _sigs,
        bytes32 _digest,
        uint256 _powerThreshold
    ) private pure {
        uint256 cumulativePower = 0;

        for (uint256 i = 0; i < _currentValidators.length; i++) {
            // If the signature is nil, then it's not present so continue.
            if (isSigNil(_sigs[i])) {
                continue;
            }

            // Check that the current validator has signed off on the hash.
            if (!verifySig(_currentValidators[i].addr, _digest, _sigs[i])) {
                revert InvalidSignature();
            }

            // Sum up cumulative power.
            cumulativePower += _currentValidators[i].power;

            // Break early to avoid wasting gas.
            if (cumulativePower >= _powerThreshold) {
                break;
            }
        }

        // Check that there was enough power.
        if (cumulativePower < _powerThreshold) {
            revert InsufficientVotingPower();
        }
    }

    /// @notice This updates the validator set by checking that the validators
    /// in the current validator set have signed off on the new validator set.
    /// The signatures supplied are the signatures of the current validator set
    /// over the checkpoint hash generated from the new validator set. Anyone
    /// can call this function, but they must supply valid signatures of the
    /// current validator set over the new validator set.
    ///
    /// The validator set hash that is signed over is domain separated as per
    /// `domainSeparateValidatorSetHash`.
    /// @param _newValidatorSetHash The hash of the new validator set.
    /// @param _newNonce The new Celestia block height.
    /// @param _currentValidatorSet The current validator set.
    /// @param _sigs Signatures.
    function updateValidatorSet(
        uint256 _newNonce,
        uint256 _newPowerThreshold,
        bytes32 _newValidatorSetHash,
        Validator[] calldata _currentValidatorSet,
        Signature[] calldata _sigs
    ) external {
        // CHECKS

        uint256 currentNonce = state_lastValidatorSetNonce;
        uint256 currentPowerThreshold = state_powerThreshold;

        // Check that the new validator set nonce is greater than the old one.
        if (_newNonce <= currentNonce) {
            revert InvalidValidatorSetNonce();
        }

        // Check that current validators and signatures are well-formed.
        if (_currentValidatorSet.length != _sigs.length) {
            revert MalformedCurrentValidatorSet();
        }

        // Check that the supplied current validator set matches the saved checkpoint.
        bytes32 currentValidatorSetHash = computeValidatorSetHash(_currentValidatorSet);
        if (
            domainSeparateValidatorSetHash(BRIDGE_ID, currentNonce, currentPowerThreshold, currentValidatorSetHash) !=
            state_lastValidatorSetCheckpoint
        ) {
            revert SuppliedValidatorSetInvalid();
        }

        // Check that enough current validators have signed off on the new validator set.
        bytes32 newCheckpoint = domainSeparateValidatorSetHash(
            BRIDGE_ID,
            _newNonce,
            _newPowerThreshold,
            _newValidatorSetHash
        );
        checkValidatorSignatures(_currentValidatorSet, _sigs, newCheckpoint, currentPowerThreshold);

        // EFFECTS

        state_lastValidatorSetCheckpoint = newCheckpoint;
        state_powerThreshold = _newPowerThreshold;
        state_lastValidatorSetNonce = _newNonce;

        // LOGS

        emit ValidatorSetUpdatedEvent(_newNonce, _newPowerThreshold, _newValidatorSetHash);
    }

    /// @notice Relays a root of Celestia data root tuples to an EVM chain. Anyone
    /// can call this function, but they must supply valid signatures of the
    /// current validator set over the data root tuple root.
    ///
    /// The data root root is the Merkle root of the binary Merkle tree
    /// (https://github.com/celestiaorg/celestia-specs/blob/master/src/specs/data_structures.md#binary-merkle-tree)
    /// where each leaf in an ABI-encoded `DataRootTuple`. Each relayed data
    /// root tuple will 1:1 mirror data roots as they are included in headers
    /// on Celestia, _in order of inclusion_.
    ///
    /// The data tuple root that is signed over is domain separated as per
    /// `domainSeparateDataRootTupleRoot`.
    /// @param _nonce The Celestia block height up to which the data root tuple
    /// root commits to.
    /// @param _dataRootTupleRoot The Merkle root of data root tuples.
    /// @param _currentValidatorSet The current validator set.
    /// @param _sigs Signatures.
    function submitDataRootTupleRoot(
        uint256 _nonce,
        bytes32 _dataRootTupleRoot,
        Validator[] calldata _currentValidatorSet,
        Signature[] calldata _sigs
    ) external {
        // CHECKS

        uint256 currentNonce = state_lastDataRootTupleRootNonce;
        uint256 currentPowerThreshold = state_powerThreshold;

        // Check that the data root tuple root nonce is higher than the last nonce.
        if (_nonce <= currentNonce) {
            revert InvalidDataRootTupleRootNonce();
        }

        // Check that current validators and signatures are well-formed.
        if (_currentValidatorSet.length != _sigs.length) {
            revert MalformedCurrentValidatorSet();
        }

        // Check that the supplied current validator set matches the saved checkpoint.
        bytes32 currentValidatorSetHash = computeValidatorSetHash(_currentValidatorSet);
        if (
            domainSeparateValidatorSetHash(
                BRIDGE_ID,
                state_lastValidatorSetNonce,
                currentPowerThreshold,
                currentValidatorSetHash
            ) != state_lastValidatorSetCheckpoint
        ) {
            revert SuppliedValidatorSetInvalid();
        }

        // Check that enough current validators have signed off on the data
        // root tuple root and nonce.
        bytes32 c = domainSeparateDataRootTupleRoot(BRIDGE_ID, currentNonce, _nonce, _dataRootTupleRoot);
        checkValidatorSignatures(_currentValidatorSet, _sigs, c, currentPowerThreshold);

        // EFFECTS

        state_lastDataRootTupleRootNonce = _nonce;
        state_dataRootTupleRoots[_nonce] = _dataRootTupleRoot;

        // LOGS

        emit DataRootTupleRootEvent(_nonce, _dataRootTupleRoot);
    }

    /// @dev see "./IDAOracle.sol"
    function verifyAttestation(
        uint256 _tupleRootIndex,
        DataRootTuple memory _tuple,
        BinaryMerkleProof memory _proof
    ) external view override returns (bool) {
        // Tuple must have been committed before.
        if (_tupleRootIndex > state_lastDataRootTupleRootNonce) {
            // 这里返回错误 因为如果tupleRootIndex大于state_lastDataRootTupleRootNonce 说明tuple没有被commit过 什么意思？
            return false;
        }

        // Load the tuple root at the given index from storage.
        bytes32 root = state_dataRootTupleRoots[_tupleRootIndex];

        // 这个应该是最核心的部分 验证proof是否是正确的
        // Verify the proof.
        bool isProofValid = BinaryMerkleTree.verify(root, _proof, abi.encode(_tuple));

        return isProofValid;
    }
}
