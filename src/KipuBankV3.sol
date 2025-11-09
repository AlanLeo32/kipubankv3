// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title KipuBankV3
 * @notice Banco multi-token con integración a Uniswap V2 Router
 * @dev Cualquier depósito (ETH o ERC20) se convierte automáticamente a USDC
 * y se acredita al balance del usuario, respetando el bank cap y threshold de retiro
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external pure returns (address);

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) 
        external view returns (address pair);
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rol de administrador para gestión del banco
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Router de Uniswap V2 para ejecutar swaps
    IUniswapV2Router02 public immutable i_router;
    
    /// @notice Factory de Uniswap V2 para verificar pares
    IUniswapV2Factory public immutable i_factory;
    
    /// @notice Token USDC (6 decimales)
    address public immutable i_usdc;
    
    /// @notice WETH para conversión de ETH nativo
    address public immutable i_weth;

    /// @notice Capacidad máxima del banco en USDC (6 decimales)
    uint256 public immutable i_bankCapUSDC;
    
    /// @notice Umbral máximo de retiro por transacción en USDC (6 decimales)
    uint256 public immutable i_withdrawalThresholdUSDC;

    /// @notice Saldos por usuario en USDC (6 decimales)
    mapping(address user => uint256 usdcBalance) private s_depositsUSDC;
    
    /// @notice Total depositado en el banco en USDC (6 decimales)
    uint256 private s_totalUSDC;

    /// @notice Protección contra slippage en basis points (300 = 3%)
    uint16 public s_maxSlippageBPS;

    /// @notice Contador de depósitos realizados
    uint256 public s_depositCount;
    
    /// @notice Contador de retiros realizados
    uint256 public s_withdrawalCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Se emite cuando un usuario deposita ETH
    event DepositETH(
        address indexed user, 
        uint256 ethIn, 
        uint256 usdcCredited
    );
    
    /// @notice Se emite cuando un usuario deposita un token ERC20
    event DepositToken(
        address indexed user, 
        address indexed token, 
        uint256 amountIn, 
        uint256 usdcCredited
    );
    
    /// @notice Se emite cuando un usuario retira USDC
    event WithdrawUSDC(
        address indexed user, 
        uint256 usdcAmount
    );
    
    /// @notice Se emite cuando se actualiza el slippage máximo
    event MaxSlippageUpdated(uint16 newBps);

    /*//////////////////////////////////////////////////////////////
                          ERRORES PERSONALIZADOS
    //////////////////////////////////////////////////////////////*/

    error KipuBank__ZeroAmount();
    error KipuBank__InvalidAddress();
    error KipuBank__TokenNotSupported(address token);
    error KipuBank__BankCapExceeded(uint256 requested, uint256 available);
    error KipuBank__InsufficientBalance(uint256 requested, uint256 available);
    error KipuBank__WithdrawalThresholdExceeded(uint256 requested, uint256 threshold);
    error KipuBank__InsufficientOutput();
    error KipuBank__ExcessiveSlippage();
    error KipuBank__InvalidSlippage();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa KipuBankV3 con parámetros del banco
     * @param _admin Dirección del administrador inicial
     * @param _router Dirección del Router de Uniswap V2
     * @param _usdc Dirección del token USDC
     * @param _bankCapUSDC Capacidad máxima en USDC (6 decimales)
     * @param _withdrawalThresholdUSDC Umbral de retiro en USDC (6 decimales)
     */
    constructor(
        address _admin,
        address _router,
        address _usdc,
        uint256 _bankCapUSDC,
        uint256 _withdrawalThresholdUSDC
    ) {
        if (_router == address(0) || _usdc == address(0) || _admin == address(0)) {
            revert KipuBank__InvalidAddress();
        }
        if (_bankCapUSDC == 0 || _withdrawalThresholdUSDC == 0) {
            revert KipuBank__ZeroAmount();
        }

        i_router = IUniswapV2Router02(_router);
        i_factory = IUniswapV2Factory(IUniswapV2Router02(_router).factory());
        i_weth = IUniswapV2Router02(_router).WETH();
        i_usdc = _usdc;
        i_bankCapUSDC = _bankCapUSDC;
        i_withdrawalThresholdUSDC = _withdrawalThresholdUSDC;
        s_maxSlippageBPS = 300; // 3% por defecto

        // Configurar roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////
                         RECEIVE & FALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recibe ETH y lo deposita automáticamente con slippage máximo
     * @dev Usa el slippage configurado en s_maxSlippageBPS
     */
    receive() external payable {
        if (msg.value == 0) revert KipuBank__ZeroAmount();
        
        // Calcular mínimo USDC con slippage máximo
        address[] memory path = new address[](2);
        path[0] = i_weth;
        path[1] = i_usdc;
        
        uint256 expectedOut = _routerGetOut(msg.value, path);
        uint256 minUSDCOut = _applySlippageGuard(expectedOut);
        
        _depositETHInternal(minUSDCOut);
    }

    /**
     * @notice Fallback rechaza llamadas con datos
     */
    fallback() external payable {
        revert KipuBank__InvalidAddress();
    }

    /*//////////////////////////////////////////////////////////////
                          FUNCIONES EXTERNAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposita ETH y lo convierte a USDC vía Uniswap V2 Router
     * @param minUSDCOut Mínimo aceptable en USDC (6 decimales) para protección contra slippage
     */
    function depositETH(uint256 minUSDCOut) external payable nonReentrant {
        if (msg.value == 0) revert KipuBank__ZeroAmount();
        _depositETHInternal(minUSDCOut);
    }

    /**
     * @notice Deposita un token ERC20 y lo convierte a USDC
     * @param token Dirección del token a depositar
     * @param amount Cantidad a depositar (decimales del token)
     * @param minUSDCOut Mínimo aceptable en USDC (6 decimales)
     * @dev Si el token es USDC, se acredita directamente sin swap
     */
    function depositToken(
        address token, 
        uint256 amount, 
        uint256 minUSDCOut
    ) external nonReentrant {
        if (amount == 0) revert KipuBank__ZeroAmount();
        if (token == address(0)) revert KipuBank__InvalidAddress();

        // Caso especial: depósito directo de USDC
        if (token == i_usdc) {
            _enforceCap(amount, minUSDCOut == 0 ? amount : minUSDCOut);
            
            IERC20(i_usdc).safeTransferFrom(msg.sender, address(this), amount);
            _creditUSDC(msg.sender, amount);
            
            emit DepositToken(msg.sender, token, amount, amount);
            return;
        }

        // Verificar que existe par directo con USDC
        if (!isDirectUSDCPair(token)) {
            revert KipuBank__TokenNotSupported(token);
        }

        // Preparar path para swap
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = i_usdc;

        // Calcular output esperado y verificar cap
        uint256 expectedOut = _routerGetOut(amount, path);
        _enforceCap(expectedOut, minUSDCOut);

        // Verificar slippage máximo configurado
        uint256 minWithGuard = _applySlippageGuard(expectedOut);
        if (minUSDCOut < minWithGuard) revert KipuBank__ExcessiveSlippage();

        // Transferir tokens del usuario y aprobar al router
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(i_router), amount);

        // Ejecutar swap
        uint[] memory amounts = i_router.swapExactTokensForTokens(
            amount,
            minUSDCOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        
        uint256 usdcReceived = amounts[amounts.length - 1];
        if (usdcReceived == 0) revert KipuBank__InsufficientOutput();

        _creditUSDC(msg.sender, usdcReceived);
        emit DepositToken(msg.sender, token, amount, usdcReceived);
    }

    /**
     * @notice Retira USDC del balance del usuario
     * @param usdcAmount Cantidad de USDC a retirar (6 decimales)
     * @dev Verifica el threshold de retiro antes de procesar
     */
    function withdrawUSDC(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert KipuBank__ZeroAmount();
        
        uint256 userBalance = s_depositsUSDC[msg.sender];
        if (userBalance < usdcAmount) {
            revert KipuBank__InsufficientBalance(usdcAmount, userBalance);
        }

        // CHECKS: Verificar threshold de retiro
        if (usdcAmount > i_withdrawalThresholdUSDC) {
            revert KipuBank__WithdrawalThresholdExceeded(
                usdcAmount, 
                i_withdrawalThresholdUSDC
            );
        }

        // EFFECTS: Actualizar estado
        s_depositsUSDC[msg.sender] = userBalance - usdcAmount;
        s_totalUSDC -= usdcAmount;
        s_withdrawalCount++;

        // INTERACTIONS: Transferir USDC
        IERC20(i_usdc).safeTransfer(msg.sender, usdcAmount);
        
        emit WithdrawUSDC(msg.sender, usdcAmount);
    }

    /**
     * @notice Actualiza el slippage máximo permitido (solo ADMIN)
     * @param newBps Nuevo slippage en basis points (ej: 300 = 3%)
     * @dev Máximo permitido: 2000 BPS (20%)
     */
    function setMaxSlippageBPS(uint16 newBps) external onlyRole(ADMIN_ROLE) {
        if (newBps > 2000) revert KipuBank__InvalidSlippage();
        
        s_maxSlippageBPS = newBps;
        emit MaxSlippageUpdated(newBps);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES INTERNAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lógica interna para depositar ETH
     * @param minUSDCOut Mínimo de USDC esperado
     */
    function _depositETHInternal(uint256 minUSDCOut) private {
        // Preparar path ETH -> USDC
        address[] memory path = new address[](2);
        path[0] = i_weth;
        path[1] = i_usdc;

        // Calcular output esperado y verificar cap
        uint256 expectedOut = _routerGetOut(msg.value, path);
        _enforceCap(expectedOut, minUSDCOut);

        // Verificar slippage máximo
        uint256 minWithGuard = _applySlippageGuard(expectedOut);
        if (minUSDCOut < minWithGuard) revert KipuBank__ExcessiveSlippage();

        // Ejecutar swap de ETH a USDC
        uint[] memory amounts = i_router.swapExactETHForTokens{value: msg.value}(
            minUSDCOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        
        uint256 usdcReceived = amounts[amounts.length - 1];
        if (usdcReceived == 0) revert KipuBank__InsufficientOutput();

        _creditUSDC(msg.sender, usdcReceived);
        emit DepositETH(msg.sender, msg.value, usdcReceived);
    }

    /**
     * @notice Aplica el slippage máximo configurado a un monto esperado
     * @param expectedOut Monto esperado
     * @return Monto mínimo después de aplicar slippage
     */
    function _applySlippageGuard(uint256 expectedOut) internal view returns (uint256) {
        return (expectedOut * (10000 - s_maxSlippageBPS)) / 10000;
    }

    /**
     * @notice Obtiene el output esperado del router para un path dado
     * @param amountIn Cantidad de entrada
     * @param path Path de tokens para el swap
     * @return Output esperado
     */
    function _routerGetOut(uint256 amountIn, address[] memory path) 
        internal 
        view 
        returns (uint256) 
    {
        uint[] memory amounts = i_router.getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    /**
     * @notice Verifica que el depósito no exceda el bank cap
     * @param expectedUSDCOut USDC esperado del swap
     * @param minUSDCOut USDC mínimo solicitado por el usuario
     */
    function _enforceCap(uint256 expectedUSDCOut, uint256 minUSDCOut) internal view {
        uint256 projected = s_totalUSDC + (minUSDCOut == 0 ? expectedUSDCOut : minUSDCOut);
        if (projected > i_bankCapUSDC) {
            revert KipuBank__BankCapExceeded(
                minUSDCOut == 0 ? expectedUSDCOut : minUSDCOut,
                i_bankCapUSDC > s_totalUSDC ? i_bankCapUSDC - s_totalUSDC : 0
            );
        }
    }

    /**
     * @notice Acredita USDC al balance del usuario con verificación final de cap
     * @param user Usuario a acreditar
     * @param amountUSDC Cantidad de USDC a acreditar
     */
    function _creditUSDC(address user, uint256 amountUSDC) internal {
        // Verificación final: nunca exceder el cap incluso si router entregó más
        uint256 newTotal = s_totalUSDC + amountUSDC;
        if (newTotal > i_bankCapUSDC) {
            revert KipuBank__BankCapExceeded(
                amountUSDC,
                i_bankCapUSDC - s_totalUSDC
            );
        }
        
        s_totalUSDC = newTotal;
        s_depositsUSDC[user] += amountUSDC;
        s_depositCount++;
    }

    /*//////////////////////////////////////////////////////////////
                          FUNCIONES VIEW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Obtiene el balance de un usuario en USDC
     * @param user Dirección del usuario
     * @return Balance en USDC (6 decimales)
     */
    function getBalanceUSDC(address user) external view returns (uint256) {
        return s_depositsUSDC[user];
    }

    /**
     * @notice Obtiene el total depositado en el banco
     * @return Total en USDC (6 decimales)
     */
    function getTotalUSDC() external view returns (uint256) {
        return s_totalUSDC;
    }

    /**
     * @notice Obtiene la capacidad disponible del banco
     * @return Capacidad disponible en USDC (6 decimales)
     */
    function getAvailableCapUSDC() public view returns (uint256) {
        return s_totalUSDC >= i_bankCapUSDC ? 0 : (i_bankCapUSDC - s_totalUSDC);
    }

    /**
     * @notice Verifica si existe par directo token-USDC en Uniswap V2
     * @param token Token a verificar
     * @return true si existe el par directo con USDC
     */
    function isDirectUSDCPair(address token) public view returns (bool) {
        if (token == i_usdc) return true;
        if (token == address(0)) return false;
        return i_factory.getPair(token, i_usdc) != address(0);
    }

    /**
     * @notice Simula cuánto USDC recibirías depositando un token
     * @param token Token a depositar
     * @param amount Cantidad del token
     * @return expectedUSDC USDC esperado (6 decimales)
     */
    function previewDepositToken(address token, uint256 amount) 
        external 
        view 
        returns (uint256 expectedUSDC) 
    {
        if (token == i_usdc) return amount;
        if (!isDirectUSDCPair(token)) return 0;
        
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = i_usdc;
        
        return _routerGetOut(amount, path);
    }

    /**
     * @notice Simula cuánto USDC recibirías depositando ETH
     * @param ethAmount Cantidad de ETH en wei
     * @return expectedUSDC USDC esperado (6 decimales)
     */
    function previewDepositETH(uint256 ethAmount) 
        external 
        view 
        returns (uint256 expectedUSDC) 
    {
        address[] memory path = new address[](2);
        path[0] = i_weth;
        path[1] = i_usdc;
        
        return _routerGetOut(ethAmount, path);
    }
}