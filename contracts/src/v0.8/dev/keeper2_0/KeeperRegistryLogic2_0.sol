// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./KeeperRegistryBase2_0.sol";
import "../../interfaces/MigratableKeeperRegistryInterface.sol";
import "../../interfaces/UpkeepTranscoderInterface.sol";

/**
 * @notice Logic contract, works in tandem with KeeperRegistry as a proxy
 */
contract KeeperRegistryLogic2_0 is KeeperRegistryBase2_0 {
  using Address for address;
  using EnumerableSet for EnumerableSet.UintSet;

  /**
   * @param paymentModel one of Default, Arbitrum, Optimism
   * @param registryGasOverhead the gas overhead used by registry in performUpkeep
   * @param link address of the LINK Token
   * @param linkNativeFeed address of the LINK/Native price feed
   * @param fastGasFeed address of the Fast Gas price feed
   */
  constructor(
    PaymentModel paymentModel,
    uint256 registryGasOverhead,
    address link,
    address linkNativeFeed,
    address fastGasFeed
  ) KeeperRegistryBase2_0(paymentModel, registryGasOverhead, link, linkNativeFeed, fastGasFeed) {}

  function checkUpkeep(uint256 id)
    external
    cannotExecute
    returns (
      bool upkeepNeeded,
      bytes memory performDataWrapped,
      UpkeepFailureReason upkeepFailureReason,
      uint256 gasUsed
    )
  {
    HotVars memory hotVars = s_hotVars;
    Upkeep memory upkeep = s_upkeep[id];
    if (upkeep.maxValidBlocknumber <= block.number)
      return (false, bytes("0x"), UpkeepFailureReason.UPKEEP_CANCELLED, gasUsed);
    if (upkeep.paused) return (false, bytes("0x"), UpkeepFailureReason.UPKEEP_PAUSED, gasUsed);

    gasUsed = gasleft();
    bytes memory callData = abi.encodeWithSelector(CHECK_SELECTOR, s_checkData[id]);
    (bool success, bytes memory result) = upkeep.target.call{gas: s_storage.checkGasLimit}(callData);
    gasUsed = gasUsed - gasleft();

    if (!success) return (false, bytes("0x"), UpkeepFailureReason.TARGET_CHECK_REVERTED, gasUsed);

    bytes memory performData;
    (upkeepNeeded, performData) = abi.decode(result, (bool, bytes));
    if (!upkeepNeeded) return (false, bytes("0x"), UpkeepFailureReason.UPKEEP_NOT_NEEDED, gasUsed);
    if (performData.length > s_storage.maxPerformDataSize)
      return (false, bytes("0x"), UpkeepFailureReason.PERFORM_DATA_EXCEEDS_LIMIT, gasUsed);

    PerformPaymentParams memory paymentParams = _generatePerformPaymentParams(upkeep, hotVars, false);
    if (upkeep.balance < paymentParams.maxLinkPayment)
      return (false, bytes("0x"), UpkeepFailureReason.INSUFFICIENT_BALANCE, gasUsed);

    performDataWrapped = abi.encode(
      PerformDataWrapper({
        checkBlockNumber: uint32(block.number),
        checkBlockhash: blockhash(block.number - 1),
        performData: performData
      })
    );
    return (true, performDataWrapped, UpkeepFailureReason.NONE, gasUsed);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function withdrawOwnerFunds() external onlyOwner {
    uint96 amount = s_storage.ownerLinkBalance;

    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance - amount;
    s_storage.ownerLinkBalance = 0;

    emit OwnerFundsWithdrawn(amount);
    LINK.transfer(msg.sender, amount);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function recoverFunds() external onlyOwner {
    uint256 total = LINK.balanceOf(address(this));
    LINK.transfer(msg.sender, total - s_storage.expectedLinkBalance);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function setPayees(address[] calldata payees) external onlyOwner {
    if (s_transmittersList.length != payees.length) revert ParameterLengthError();
    for (uint256 i = 0; i < s_transmittersList.length; i++) {
      address transmitter = s_transmittersList[i];
      address oldPayee = s_transmitterPayees[transmitter];
      address newPayee = payees[i];
      if (
        (newPayee == ZERO_ADDRESS) || (oldPayee != ZERO_ADDRESS && oldPayee != newPayee && newPayee != IGNORE_ADDRESS)
      ) revert InvalidPayee();
      if (newPayee != IGNORE_ADDRESS) {
        s_transmitterPayees[transmitter] = newPayee;
      }
    }
    emit PayeesUpdated(s_transmittersList, payees);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function pause() external onlyOwner {
    _pause();
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function unpause() external onlyOwner {
    _unpause();
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function setPeerRegistryMigrationPermission(address peer, MigrationPermission permission) external onlyOwner {
    s_peerRegistryMigrationPermission[peer] = permission;
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function registerUpkeep(
    address target,
    uint32 gasLimit,
    address admin,
    bytes calldata checkData
  ) external returns (uint256 id) {
    if (msg.sender != owner() && msg.sender != s_storage.registrar) revert OnlyCallableByOwnerOrRegistrar();

    id = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), address(this), s_storage.nonce)));
    _createUpkeep(id, target, gasLimit, admin, 0, checkData, false);
    s_storage.nonce++;
    emit UpkeepRegistered(id, gasLimit, admin);
    return id;
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function cancelUpkeep(uint256 id) external {
    Upkeep memory upkeep = s_upkeep[id];
    bool canceled = upkeep.maxValidBlocknumber != UINT32_MAX;
    bool isOwner = msg.sender == owner();

    if (canceled && !(isOwner && upkeep.maxValidBlocknumber > block.number)) revert CannotCancel();
    if (!isOwner && msg.sender != s_upkeepAdmin[id]) revert OnlyCallableByOwnerOrAdmin();

    uint256 height = block.number;
    if (!isOwner) {
      height = height + CANCELLATION_DELAY;
    }
    s_upkeep[id].maxValidBlocknumber = uint32(height);
    s_upkeepIDs.remove(id);

    // charge the cancellation fee if the minUpkeepSpend is not met
    uint96 minUpkeepSpend = s_storage.minUpkeepSpend;
    uint96 cancellationFee = 0;
    // cancellationFee is supposed to be min(max(minUpkeepSpend - amountSpent,0), amountLeft)
    if (upkeep.amountSpent < minUpkeepSpend) {
      cancellationFee = minUpkeepSpend - upkeep.amountSpent;
      if (cancellationFee > upkeep.balance) {
        cancellationFee = upkeep.balance;
      }
    }
    s_upkeep[id].balance = upkeep.balance - cancellationFee;
    s_storage.ownerLinkBalance = s_storage.ownerLinkBalance + cancellationFee;

    emit UpkeepCanceled(id, uint64(height));
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function addFunds(uint256 id, uint96 amount) external {
    Upkeep memory upkeep = s_upkeep[id];
    if (upkeep.maxValidBlocknumber != UINT32_MAX) revert UpkeepCancelled();

    s_upkeep[id].balance = upkeep.balance + amount;
    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance + amount;
    LINK.transferFrom(msg.sender, address(this), amount);
    emit FundsAdded(id, msg.sender, amount);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function withdrawFunds(uint256 id, address to) external {
    if (to == ZERO_ADDRESS) revert InvalidRecipient();
    Upkeep memory upkeep = s_upkeep[id];
    if (s_upkeepAdmin[id] != msg.sender) revert OnlyCallableByAdmin();
    if (upkeep.maxValidBlocknumber > block.number) revert UpkeepNotCanceled();

    uint96 amountToWithdraw = s_upkeep[id].balance;
    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance - amountToWithdraw;
    s_upkeep[id].balance = 0;
    emit FundsWithdrawn(id, amountToWithdraw, to);

    LINK.transfer(to, amountToWithdraw);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function setUpkeepGasLimit(uint256 id, uint32 gasLimit) external {
    if (gasLimit < PERFORM_GAS_MIN || gasLimit > s_storage.maxPerformGas) revert GasLimitOutsideRange();
    Upkeep memory upkeep = s_upkeep[id];
    if (upkeep.maxValidBlocknumber != UINT32_MAX) revert UpkeepCancelled();
    if (s_upkeepAdmin[id] != msg.sender) revert OnlyCallableByAdmin();

    s_upkeep[id].executeGas = gasLimit;

    emit UpkeepGasLimitSet(id, gasLimit);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function withdrawPayment(address from, address to) external {
    if (to == ZERO_ADDRESS) revert InvalidRecipient();
    Transmitter memory transmitter = s_transmitters[from];
    if (s_transmitterPayees[from] != msg.sender) revert OnlyCallableByPayee();

    s_transmitters[from].balance = 0;
    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance - transmitter.balance;
    emit PaymentWithdrawn(from, transmitter.balance, to, msg.sender);

    LINK.transfer(to, transmitter.balance);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function transferPayeeship(address transmitter, address proposed) external {
    if (s_transmitterPayees[transmitter] != msg.sender) revert OnlyCallableByPayee();
    if (proposed == msg.sender) revert ValueNotChanged();

    if (s_proposedPayee[transmitter] != proposed) {
      s_proposedPayee[transmitter] = proposed;
      emit PayeeshipTransferRequested(transmitter, msg.sender, proposed);
    }
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function acceptPayeeship(address transmitter) external {
    if (s_proposedPayee[transmitter] != msg.sender) revert OnlyCallableByProposedPayee();
    address past = s_transmitterPayees[transmitter];
    s_transmitterPayees[transmitter] = msg.sender;
    s_proposedPayee[transmitter] = ZERO_ADDRESS;

    emit PayeeshipTransferred(transmitter, past, msg.sender);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function transferUpkeepAdmin(uint256 id, address proposed) external {
    requireAdminAndNotCancelled(id);
    if (proposed == msg.sender) revert ValueNotChanged();
    if (proposed == ZERO_ADDRESS) revert InvalidRecipient();

    if (s_proposedAdmin[id] != proposed) {
      s_proposedAdmin[id] = proposed;
      emit UpkeepAdminTransferRequested(id, msg.sender, proposed);
    }
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function acceptUpkeepAdmin(uint256 id) external {
    Upkeep memory upkeep = s_upkeep[id];
    if (upkeep.maxValidBlocknumber != UINT32_MAX) revert UpkeepCancelled();
    if (s_proposedAdmin[id] != msg.sender) revert OnlyCallableByProposedAdmin();
    address past = s_upkeepAdmin[id];
    s_upkeepAdmin[id] = msg.sender;
    s_proposedAdmin[id] = ZERO_ADDRESS;

    emit UpkeepAdminTransferred(id, past, msg.sender);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function migrateUpkeeps(uint256[] calldata ids, address destination) external {
    if (
      s_peerRegistryMigrationPermission[destination] != MigrationPermission.OUTGOING &&
      s_peerRegistryMigrationPermission[destination] != MigrationPermission.BIDIRECTIONAL
    ) revert MigrationNotPermitted();
    if (s_storage.transcoder == ZERO_ADDRESS) revert TranscoderNotSet();
    if (ids.length == 0) revert ArrayHasNoEntries();
    uint256 id;
    Upkeep memory upkeep;
    uint256 totalBalanceRemaining;
    bytes[] memory checkDatas = new bytes[](ids.length);
    address[] memory admins = new address[](ids.length);
    Upkeep[] memory upkeeps = new Upkeep[](ids.length);
    for (uint256 idx = 0; idx < ids.length; idx++) {
      id = ids[idx];
      upkeep = s_upkeep[id];
      requireAdminAndNotCancelled(id);
      upkeeps[idx] = upkeep;
      checkDatas[idx] = s_checkData[id];
      admins[idx] = s_upkeepAdmin[id];
      totalBalanceRemaining = totalBalanceRemaining + upkeep.balance;
      delete s_upkeep[id];
      delete s_checkData[id];
      // nullify existing proposed admin change if an upkeep is being migrated
      delete s_proposedAdmin[id];
      s_upkeepIDs.remove(id);
      emit UpkeepMigrated(id, upkeep.balance, destination);
    }
    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance - totalBalanceRemaining;
    bytes memory encodedUpkeeps = abi.encode(ids, upkeeps, checkDatas, admins);
    MigratableKeeperRegistryInterface(destination).receiveUpkeeps(
      UpkeepTranscoderInterface(s_storage.transcoder).transcodeUpkeeps(
        UPKEEP_TRANSCODER_VERSION_BASE,
        MigratableKeeperRegistryInterface(destination).upkeepTranscoderVersion(),
        encodedUpkeeps
      )
    );
    LINK.transfer(destination, totalBalanceRemaining);
  }

  /**
   * @dev Called through KeeperRegistry main contract
   */
  function receiveUpkeeps(bytes calldata encodedUpkeeps) external {
    if (
      s_peerRegistryMigrationPermission[msg.sender] != MigrationPermission.INCOMING &&
      s_peerRegistryMigrationPermission[msg.sender] != MigrationPermission.BIDIRECTIONAL
    ) revert MigrationNotPermitted();
    (uint256[] memory ids, Upkeep[] memory upkeeps, bytes[] memory checkDatas, address[] memory upkeepAdmins) = abi
      .decode(encodedUpkeeps, (uint256[], Upkeep[], bytes[], address[]));
    for (uint256 idx = 0; idx < ids.length; idx++) {
      _createUpkeep(
        ids[idx],
        upkeeps[idx].target,
        upkeeps[idx].executeGas,
        upkeepAdmins[idx],
        upkeeps[idx].balance,
        checkDatas[idx],
        upkeeps[idx].paused
      );
      emit UpkeepReceived(ids[idx], upkeeps[idx].balance, msg.sender);
    }
  }

  /**
   * @notice creates a new upkeep with the given fields
   * @param target address to perform upkeep on
   * @param gasLimit amount of gas to provide the target contract when
   * performing upkeep
   * @param admin address to cancel upkeep and withdraw remaining funds
   * @param checkData data passed to the contract when checking for upkeep
   * @param paused if this upkeep is paused
   */
  function _createUpkeep(
    uint256 id,
    address target,
    uint32 gasLimit,
    address admin,
    uint96 balance,
    bytes memory checkData,
    bool paused
  ) internal whenNotPaused {
    if (!target.isContract()) revert NotAContract();
    if (checkData.length > s_storage.maxCheckDataSize) revert CheckDataExceedsLimit();
    if (gasLimit < PERFORM_GAS_MIN || gasLimit > s_storage.maxPerformGas) revert GasLimitOutsideRange();
    s_upkeep[id] = Upkeep({
      target: target,
      executeGas: gasLimit,
      balance: balance,
      maxValidBlocknumber: UINT32_MAX,
      lastPerformBlockNumber: 0,
      amountSpent: 0,
      paused: paused
    });
    s_upkeepAdmin[id] = admin;
    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance + balance;
    s_checkData[id] = checkData;
    s_upkeepIDs.add(id);
  }
}