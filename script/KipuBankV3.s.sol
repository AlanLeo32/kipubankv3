// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
    // Configuración Sepolia
    address constant ADMIN = 0x8f426d27c14d212482CC4644a396A06DE35a611C;
    address constant ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008; // Uniswap V2 Router Sepolia
    address constant USDC   = 0xf08A50178dfcDe18524640EA6618a1f965821715; // USDC Sepolia

    // Límites del banco (en USDC, 6 decimales)
    uint256 constant BANK_CAP = 1_000_000 * 10**6;        // 1 millón
    uint256 constant WITHDRAW_CAP = 10_000 * 10**6;       // 10 mil

    function run() external {
        vm.startBroadcast();

        // Desplegar el contrato con parámetros correctos
        KipuBankV3 bank = new KipuBankV3(
            ADMIN,
            ROUTER,
            USDC,
            BANK_CAP,
            WITHDRAW_CAP
        );
        console.log("KipuBankV3 desplegado en:", address(bank));

        vm.stopBroadcast();
    }
}
