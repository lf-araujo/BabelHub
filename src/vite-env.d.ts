/// <reference types="vite/client" />

declare module '*.org?raw' {
  const content: string;
  export default content;
}
