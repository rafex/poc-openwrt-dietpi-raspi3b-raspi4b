/// <reference types="vite/client" />

// Permitir imports de archivos CSS/SCSS como side-effects
declare module '*.scss' {
  const content: Record<string, string>
  export default content
}
declare module '*.css' {
  const content: Record<string, string>
  export default content
}
