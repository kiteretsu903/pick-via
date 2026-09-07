# PickVia

<p align="center">
  <img src="Support/Icons/PickViaArtwork.png" alt="Icono de la aplicación PickVia" width="128">
</p>

<p align="center"><strong>Deja de abrir enlaces en el navegador o perfil equivocado.</strong></p>

macOS puede reutilizar una ventana o un perfil de navegador equivocados, mientras que todos los enlaces `mailto:` se abren en una única aplicación de correo predeterminada. PickVia te pregunta dónde abrir cada enlace, para que elijas el perfil de navegador o la aplicación de correo instalada que necesitas.

**[Visita el sitio web de PickVia](https://kiteretsu903.github.io/pick-via/)** para ver capturas de pantalla, novedades de las versiones y el [historial de cambios](https://kiteretsu903.github.io/pick-via/changelog.html).

<p align="center">
  <img src="docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="Selector de navegador de PickVia con material translúcido nativo de macOS" width="900">
</p>

## Idiomas

PickVia v1.5 admite 80 idiomas para la aplicación y el sitio web, con un selector de idioma y diseños de derecha a izquierda, además de 12 idiomas para el README. Elige el idioma de la aplicación en Ajustes o utiliza el idioma principal del sistema. Las capturas del producto muestran la interfaz en inglés.

## Descarga

**[Descargar PickVia v1.5 para macOS](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia requiere **macOS 14 Sonoma o posterior** en **Apple Silicon** y gestiona enlaces HTTP, HTTPS y `mailto:`.

## Qué hace

- **Permite elegir un navegador o perfil para cada enlace web.**
- **Permite elegir una aplicación de correo instalada para cada enlace de correo.**
- **Gestiona los enlaces localmente sin guardar un historial de los enlaces abiertos.**

## Selector de correo

<p align="center">
  <img src="docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="Selector de correo de PickVia con material translúcido nativo de macOS" width="900">
</p>

## Configúralo una vez

Activa, desactiva, reordena y vuelve a buscar destinos de navegador y aplicaciones de correo registradas en Ajustes.

<p align="center">
  <img src="docs/screenshots/pickvia-settings@2x.png" alt="Ajustes de navegador de PickVia con perfiles de navegador de ejemplo" width="900">
</p>

## Instalación

1. Descarga y abre `PickVia-v1.5.dmg` desde la [versión de GitHub](https://github.com/kiteretsu903/pick-via/releases/latest).
2. Arrastra **PickVia** a la carpeta **Aplicaciones** que aparece en el instalador.
3. Abre **PickVia** desde Aplicaciones y sigue los pasos de bienvenida.
4. Elige **Establecer como predeterminado**. macOS solicita permiso por separado para gestionar enlaces HTTP y HTTPS.
5. Si lo deseas, revisa las aplicaciones de correo instaladas y establece PickVia como gestor predeterminado de enlaces `mailto:`, o elige **Omitir configuración de correo**.

### Primer inicio y Gatekeeper

PickVia v1.5 está firmado con un certificado Apple Development y no está notarizado. macOS puede bloquear el primer inicio de la aplicación descargada. Si la descargaste desde la versión de GitHub y decides confiar en ella:

1. Intenta abrir PickVia una vez y cierra la advertencia.
2. Abre **Ajustes del Sistema → Privacidad y seguridad** y desplázate hasta **Seguridad**.
3. Haz clic en **Abrir igualmente** y después confirma con **Abrir**. El botón está disponible durante aproximadamente una hora después del intento de inicio bloqueado.

Si **Abrir igualmente** no está disponible, comprueba que **PickVia.app** esté en Aplicaciones, intenta abrirla una vez para que se produzca el bloqueo y ejecuta:

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple documenta esta excepción de Gatekeeper y sus implicaciones de seguridad en [Abrir apps de forma segura en el Mac](https://support.apple.com/en-asia/102445).

## Compatibilidad con navegadores

| Navegador / ediciones | Perfiles | Normal | Ventana privada |
|---|---:|---:|---:|
| Safari | Experimental | Sí | No |
| Safari Technology Preview | No | Sí | No |
| DuckDuckGo | No | Sí | Sí* |
| Chrome Stable / Beta / Dev / Canary, Chromium | Sí | Sí | Sí |
| Edge Stable / Beta / Dev / Canary | Sí | Sí | Sí |
| Brave Stable / Beta / Nightly | Sí | Sí | Sí |
| Vivaldi Stable / Snapshot | Sí | Sí | Sí |
| Firefox Stable / Developer Edition / Nightly | Sí | Sí | Sí |
| Opera, Arc, Orion | No | Sí | No |

\* DuckDuckGo privado utiliza datos aislados y desechables en versiones compatibles sin aislamiento de aplicaciones (actualmente, la familia de versiones 1.203.x). No requiere ninguna extensión de DuckDuckGo ni acceso de Accesibilidad. Los enlaces normales de DuckDuckGo no requieren una versión concreta ni una firma del editor. Los datos privados se eliminan cuando termina el proceso del navegador mientras PickVia está en ejecución, o en un inicio o apertura de enlace posterior.

Cada edición instalada aparece como un navegador independiente, con su propio nombre e icono. Los perfiles de Firefox asociados a otra edición instalada se excluyen de la lista de perfiles de ese navegador. La asociación se basa en la ruta de la aplicación registrada por Firefox; los perfiles cuyos metadatos falten o no se reconozcan conservan el comportamiento alternativo existente y pueden aparecer en más de una edición.

Los destinos predeterminados de cada navegador funcionan sin acceso a los perfiles; conceder acceso añade los perfiles detectados. Las ventanas privadas se eligen a nivel de navegador: no se admite combinar un perfil concreto con el modo privado. Actualmente, Opera, Arc y Orion solo permiten abrir enlaces normalmente a nivel de aplicación.

La compatibilidad varía según la versión del navegador y su estado de inicio.

## Perfiles de Safari (experimental)

Activa los perfiles de Safari Stable en los ajustes de navegador. Esta función opcional requiere permisos de Accesibilidad (Control del dispositivo y acceso a los datos en macOS 27 o posterior) y Automatización. Cada enlace se abre en una nueva ventana del perfil seleccionado. La apertura de enlaces en perfiles de Safari sigue siendo experimental.

Para las compilaciones locales, establece `PICKVIA_SIGNING_IDENTITY` con la huella de tu certificado de firma de código, o guárdala en el archivo ignorado `.signing-identity`, y después ejecuta `scripts/build-app.sh`. Mantén la misma identidad entre compilaciones para conservar la identidad de la aplicación a efectos de los permisos de macOS.

## Compatibilidad con correo

PickVia solo gestiona enlaces `mailto:`. Detecta las aplicaciones instaladas que macOS registra para enlaces de correo y permite elegir la aplicación, no cuentas, perfiles, identidades ni modos de redacción. Los ajustes de correo permiten activar, desactivar, reordenar y volver a buscar los gestores registrados; configurar el correo sigue siendo opcional durante la bienvenida.

## Privacidad

- Las URL abiertas se gestionan localmente; PickVia nunca las envía, registra ni guarda.
- PickVia no accede al historial de navegación, cookies, sesiones, contraseñas guardadas ni contenido de las páginas.
- El selector de correo no muestra vistas previas, registra ni guarda los destinatarios, asuntos, cuerpos de los mensajes ni la solicitud `mailto:` original.

Elimina los permisos de acceso a perfiles en **Ajustes de navegador → Acceso a perfiles → Eliminar acceso**.

Consulta la [Política de privacidad](https://kiteretsu903.github.io/pick-via/privacy.html) completa.

## Licencia

MIT. Consulta [LICENSE](LICENSE).
