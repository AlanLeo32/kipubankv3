KipuBankV3 — Banco DeFi multi-token con integración a Uniswap V2

Descripción General

**KipuBankV3** es una evolución directa de **KipuBankV2**, transformando un banco básico de depósitos y retiros en una aplicación **DeFi totalmente integrada** con **Uniswap V2**.  

El contrato permite a los usuarios depositar **ETH o cualquier token ERC20 que tenga un par directo con USDC** en Uniswap V2.  
Automáticamente, los tokens depositados se **intercambian por USDC**, acreditándose el valor correspondiente al balance del usuario dentro del banco.  

De esta forma, KipuBankV3 abstrae la complejidad del enrutamiento de tokens, unificando todos los balances en una sola unidad estable (USDC), mientras **respeta límites de capacidad y seguridad** establecidos por el administrador.


##  Mejoras Implementadas

###  1. Integración con Uniswap V2
Se incorporó el router y factory de **Uniswap V2** (`IUniswapV2Router02` y `IUniswapV2Factory`) para ejecutar intercambios automáticos desde cualquier token soportado a USDC.  
Esto convierte a KipuBankV3 en un banco verdaderamente **multi-token**.

- ETH depositado → se convierte a USDC mediante el path `[WETH → USDC]`.  
- Cualquier token ERC20 → se convierte a USDC mediante `[token → USDC]`.  
- Si el token ya es **USDC**, se acredita directamente sin swap.

---

###  2. Capacidad Máxima y Umbral de Retiros
Se añadieron dos parámetros inmutables:
- `i_bankCapUSDC`: máximo total que el banco puede almacenar (en USDC).
- `i_withdrawalThresholdUSDC`: monto máximo que puede retirarse en una sola transacción.

Esto garantiza **estabilidad y control del riesgo de liquidez** del contrato.

---

###  3. Protección contra Slippage y Errores Personalizados
- Cada depósito ejecuta swaps con **protección contra slippage**, definida por `s_maxSlippageBPS` (por defecto 3%).  
- El administrador puede actualizar este valor con límites de seguridad (máximo 20%).  
- Se agregaron **errores personalizados** para revertir ante condiciones inválidas, mejorando la legibilidad del código y el uso de gas.

---

### 4. Preservación de la Lógica de KipuBankV2
KipuBankV3 mantiene todas las características base:
- Depósitos y retiros controlados.
- Roles de administración (`AccessControl` de OpenZeppelin).
- Protección contra reentradas (`ReentrancyGuard`).
- Manejo seguro de tokens (`SafeERC20`).

---

##  Estructura del Contrato

| Categoría | Descripción |
|------------|-------------|
| **Roles** | `ADMIN_ROLE` y `DEFAULT_ADMIN_ROLE` controlan slippage y parámetros. |
| **Tokens Soportados** | ETH, USDC y cualquier token ERC20 con par directo en Uniswap V2. |
| **Eventos** | `DepositETH`, `DepositToken`, `WithdrawUSDC`, `MaxSlippageUpdated`. |
| **Funciones Clave** | `depositETH`, `depositToken`, `withdrawUSDC`, `setMaxSlippageBPS`. |
| **View Helpers** | `getBalanceUSDC`, `getTotalUSDC`, `previewDepositETH`, `previewDepositToken`. |

---
## Notas sobre decisiones de diseño y trade-offs

Durante el desarrollo de KipuBankV3 se tomaron decisiones técnicas enfocadas en la seguridad, automatización y transparencia, pero cada una implicó ciertos trade-offs (compromisos):

## Seguridad vs Simplicidad

Se utilizó el sistema de roles de OpenZeppelin AccessControl para proteger funciones administrativas.

Ventaja: Mayor control sobre quién puede ejecutar funciones críticas.

Desventaja: El código es más complejo y requiere una gestión cuidadosa de los permisos.

## Automatización vs Control manual

El despliegue se realiza mediante un script automatizado (forge script) que también verifica el contrato en Etherscan.

Ventaja: Facilita el proceso de deployment, reduce errores humanos y mejora la reproducibilidad.

Desventaja: Menos flexibilidad en ajustes avanzados (como configuración de gas o parámetros específicos en runtime).

## Límite del banco (bankCap) (Estabilidad vs Escalabilidad)

El contrato impone un tope máximo (bankCap) de USDC almacenado.

Ventaja: Protege la solvencia del banco y previene acumulaciones excesivas.

Desventaja: Limita el crecimiento del sistema — una vez alcanzado el cap, no se permiten más depósitos hasta que haya retiros.

## Conversión automática a USDC (Comodidad vs Flexibilidad)

Cada depósito —ya sea en ETH o tokens ERC20— se convierte automáticamente a USDC.

Ventaja: Simplifica la contabilidad y unifica todos los saldos bajo una sola moneda estable.

Desventaja: El usuario pierde control sobre en qué token desea mantener su saldo, y depende totalmente de las condiciones de Uniswap (precio y liquidez).
##  Instrucciones de Despliegue

###  Requisitos Previos
- Node.js y Foundry instalados.
- Cuenta de Infura y Etherscan API Key.
- Private key de una wallet (por ejemplo, MetaMask).

###  Variables de entorno (`.env`)
Crea un archivo `.env` con:


```bash
PRIVATE_KEY=0xTU_CLAVE_PRIVADA
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/TU_API_KEY
ETHERSCAN_API_KEY=TU_ETHERSCAN_API_KEY

