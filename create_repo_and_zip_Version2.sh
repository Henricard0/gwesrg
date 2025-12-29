#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="orbit-merged"
rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"

# Create directories
mkdir -p "$ROOT_DIR/functions"
mkdir -p "$ROOT_DIR/components"
mkdir -p "$ROOT_DIR/services"
mkdir -p "$ROOT_DIR/src" || true

# Write files (shortened versions where large sections were elided earlier)
cat > "$ROOT_DIR/functions/approveStudentAccess.ts" <<'EOF'
import { createClientFromRequest } from 'npm:@base44/sdk@0.8.4';

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    
    // Verificar autenticação
    const user = await base44.auth.me();
    const isAdmin = user.role === 'admin';
    const isTeacher = user.role === 'teacher' || user.user_role === 'teacher';
    
    if (!user || (!isAdmin && !isTeacher)) {
      return Response.json({ error: 'Não autorizado' }, { status: 401 });
    }

    const { requestId, status, notes } = await req.json();

    // MIGRAÇÃO AUTOMÁTICA: Processar TODAS as solicitações aprovadas sem idioma
    const allApprovedRequests = await base44.asServiceRole.entities.StudentAccessRequest.filter({ 
      status: 'approved' 
    });

    for (const approvedRequest of allApprovedRequests) {
      const [existingUser] = await base44.asServiceRole.entities.User.filter({ 
        email: approvedRequest.user_email 
      });
      
      if (existingUser) {
        const currentLanguages = existingUser.assigned_languages || [];
        
        // Se o usuário não tem o idioma da solicitação aprovada, adicionar
        if (!currentLanguages.includes(approvedRequest.language_code)) {
          await base44.asServiceRole.entities.User.update(existingUser.id, {
            assigned_languages: [...currentLanguages, approvedRequest.language_code]
          });
        }
      }
    }

    // Buscar a solicitação atual
    const [request] = await base44.asServiceRole.entities.StudentAccessRequest.filter({ id: requestId });
    
    if (!request) {
      return Response.json({ error: 'Solicitação não encontrada' }, { status: 404 });
    }

    // Se for aprovação, adicionar o idioma ao usuário
    if (status === 'approved') {
      const [targetUser] = await base44.asServiceRole.entities.User.filter({ email: request.user_email });
      
      if (targetUser) {
        const currentLanguages = targetUser.assigned_languages || [];
        const updatedLanguages = currentLanguages.includes(request.language_code)
          ? currentLanguages
          : [...currentLanguages, request.language_code];

        await base44.asServiceRole.entities.User.update(targetUser.id, {
          assigned_languages: updatedLanguages
        });
      }
    }

    // Atualizar a solicitação
    await base44.asServiceRole.entities.StudentAccessRequest.update(requestId, {
      status,
      teacher_notes: notes,
      approved_by: user.email
    });

    return Response.json({ 
      success: true,
      message: status === 'approved' ? 'Aluno aprovado e acesso concedido!' : 'Solicitação rejeitada'
    });

  } catch (error) {
    console.error('Error:', error);
    return Response.json({ error: error.message }, { status: 500 });
  }
});
EOF

cat > "$ROOT_DIR/functions/elevenLabsTTS.ts" <<'EOF'
import { createClientFromRequest } from 'npm:@base44/sdk@0.8.4';

// Voice IDs por idioma (configure conforme suas vozes do ElevenLabs)
const VOICE_MAP = {
    'pt': 'pNInz6obpgDQGcFmaJgB',
    'en': 'EXAVITQu4vr4xnSDxMaL',
    'it': 'XB0fDUnXU5powFXDhCwa',
    'es': 'onwK4e9ZLuTAKqWW03F9',
    'default': 'pNInz6obpgDQGcFmaJgB'
};

function detectLanguage(text) {
    const lowerText = text.toLowerCase();
    if (/\b(você|está|são|não|sim|muito|mais|como|que|para|onde)\b/.test(lowerText)) return 'pt';
    if (/\b(you|are|the|is|and|what|how|where|when|why)\b/.test(lowerText)) return 'en';
    if (/\b(sei|come|dove|quando|perché|cosa|sono|molto)\b/.test(lowerText)) return 'it';
    if (/\b(eres|cómo|dónde|cuándo|por qué|qué|son|muy)\b/.test(lowerText)) return 'es';
    return 'default';
}

Deno.serve(async (req) => {
    try {
        const base44 = createClientFromRequest(req);
        const user = await base44.auth.me();
        if (!user) {
            return Response.json({ error: 'Unauthorized' }, { status: 401 });
        }

        const { text, language } = await req.json();
        if (!text || text.trim().length === 0) {
            return Response.json({ error: 'Text is required' }, { status: 400 });
        }

        const ELEVENLABS_API_KEY = Deno.env.get('ELEVENLABS_API_KEY');
        if (!ELEVENLABS_API_KEY) {
            return Response.json({ error: 'ElevenLabs API key not configured' }, { status: 500 });
        }

        const detectedLang = language || detectLanguage(text);
        const voiceId = VOICE_MAP[detectedLang] || VOICE_MAP['default'];

        const response = await fetch(
            `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
            {
                method: 'POST',
                headers: {
                    'Accept': 'audio/mpeg',
                    'Content-Type': 'application/json',
                    'xi-api-key': ELEVENLABS_API_KEY,
                },
                body: JSON.stringify({
                    text: text,
                    model_id: 'eleven_multilingual_v2',
                    voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true },
                }),
            }
        );

        if (!response.ok) {
            const error = await response.text();
            console.error('ElevenLabs API error:', error);
            return Response.json({ error: 'Failed to generate speech' }, { status: response.status });
        }

        const audioBuffer = await response.arrayBuffer();
        return new Response(audioBuffer, {
            status: 200,
            headers: { 'Content-Type': 'audio/mpeg', 'Content-Length': audioBuffer.byteLength.toString() },
        });

    } catch (error) {
        console.error('Error in elevenLabsTTS:', error);
        return Response.json({ error: error.message }, { status: 500 });
    }
});
EOF

cat > "$ROOT_DIR/functions/getMyStudents.ts" <<'EOF'
import { createClientFromRequest } from 'npm:@base44/sdk@0.8.4';

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();
    const isAdmin = user.role === 'admin';
    const isTeacher = user.role === 'teacher' || user.user_role === 'teacher';

    if (!user || (!isAdmin && !isTeacher)) {
      return Response.json({ error: 'Não autorizado' }, { status: 401 });
    }

    const allUsers = await base44.asServiceRole.entities.User.list();
    const allProgress = await base44.asServiceRole.entities.StudentProgress.list();
    const approvedRequests = await base44.asServiceRole.entities.StudentAccessRequest.filter({ status: 'approved' });
    const approvedStudentEmails = new Set(approvedRequests.map(r => r.user_email));

    let students = allUsers.filter(u => {
      if (u.email === user.email) return false;
      const role = u.role || u.user_role;
      if (role === 'admin' || role === 'teacher' || role === 'teacher_pending') return false;
      if (approvedStudentEmails.has(u.email)) return true;
      const hasProgress = allProgress.some(p => p.user_email === u.email);
      if (hasProgress) return true;
      if (u.assigned_languages && u.assigned_languages.length > 0) return true;
      return false;
    });

    if (isAdmin) {
      return Response.json({ students });
    }

    const teacherLanguages = user.assigned_languages || [];
    if (teacherLanguages.length === 0) return Response.json({ students });

    students = students.filter(student => {
      const studentLanguages = student.assigned_languages || [];
      if (studentLanguages.some(lang => teacherLanguages.includes(lang))) return true;
      const studentProgress = allProgress.filter(p => p.user_email === student.email);
      if (studentProgress.some(p => teacherLanguages.includes(p.language_code))) return true;
      const studentRequest = approvedRequests.find(r => r.user_email === student.email);
      if (studentRequest && teacherLanguages.includes(studentRequest.language_code)) return true;
      return false;
    });

    return Response.json({ students });
  } catch (error) {
    console.error('Error:', error);
    return Response.json({ error: error.message }, { status: 500 });
  }
});
EOF

cat > "$ROOT_DIR/vite.config.js" <<'EOF'
import base44 from "@base44/vite-plugin"
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  logLevel: 'error',
  plugins: [
    base44({
      legacySDKImports: process.env.BASE44_LEGACY_SDK_IMPORTS === 'true'
    }),
    react(),
  ]
});
EOF

cat > "$ROOT_DIR/.gitignore" <<'EOF'
#env
.env
.env.*

# Logs
logs
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
lerna-debug.log*

node_modules
dist
dist-ssr
*.local

# Editor directories and files
.vscode/*
!.vscode/extensions.json
.idea
.DS_Store
*.suo
*.ntvs*
*.njsproj
*.sln
*.sw?

.env
EOF

cat > "$ROOT_DIR/components.json" <<'EOF'
{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "new-york",
  "rsc": false,
  "tsx": false,
  "tailwind": {
    "config": "tailwind.config.js",
    "css": "src/index.css",
    "baseColor": "neutral",
    "cssVariables": true,
    "prefix": ""
  },
  "aliases": {
    "components": "@/components",
    "utils": "@/lib/utils",
    "ui": "@/components/ui",
    "lib": "@/lib",
    "hooks": "@/hooks"
  },
  "iconLibrary": "lucide"
}
EOF

cat > "$ROOT_DIR/eslint.config.js" <<'EOF'
import globals from "globals";
import pluginJs from "@eslint/js";
import pluginReact from "eslint-plugin-react";
import pluginReactHooks from "eslint-plugin-react-hooks";
import pluginUnusedImports from "eslint-plugin-unused-imports";

export default [
  {
    files: [
      "src/components/**/*.{js,mjs,cjs,jsx}",
      "src/pages/**/*.{js,mjs,cjs,jsx}",
      "src/Layout.jsx",
    ],
    ...pluginJs.configs.recommended,
    ...pluginReact.configs.flat.recommended,
    languageOptions: {
      globals: globals.browser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: "module",
        ecmaFeatures: {
          jsx: true,
        },
      },
    },
    settings: {
      react: {
        version: "detect",
      },
    },
    plugins: {
      react: pluginReact,
      "react-hooks": pluginReactHooks,
      "unused-imports": pluginUnusedImports,
    },
    rules: {
      "no-unused-vars": "off",
      "react/jsx-uses-vars": "error",
      "unused-imports/no-unused-imports": "error",
      "unused-imports/no-unused-vars": [
        "warn",
        {
          vars: "all",
          varsIgnorePattern: "^_",
          args: "after-used",
          argsIgnorePattern: "^_",
        },
      ],
      "react/prop-types": "off",
      "react/react-in-jsx-scope": "off",
      "react/no-unknown-property": [
        "error",
        { ignore: ["cmdk-input-wrapper", "toast-close"] },
      ],
      "react-hooks/rules-of-hooks": "error",
    },
  },
];
EOF

cat > "$ROOT_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="https://base44.com/logo_v2.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link rel="manifest" href="/manifest.json" />
    <title>Base44 APP</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat > "$ROOT_DIR/jsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["./src/*"]
    },
    "jsx": "react-jsx",
    "module": "esnext",
    "moduleResolution": "bundler",
    "lib": ["esnext", "dom"],
    "target": "esnext",
    "checkJs": true,
    "skipLibCheck": true,
    "allowSyntheticDefaultImports": true,
    "esModuleInterop": true,
    "resolveJsonModule": true,
    "types": []
  },
  "include": ["src/components/**/*.js", "src/pages/**/*.jsx", "src/Layout.jsx"],
  "exclude": ["node_modules", "dist", "src/vite-plugins", "src/components/ui", "src/api", "src/lib"]
}
EOF

cat > "$ROOT_DIR/package.json" <<'EOF'
{
  "name": "base44-app",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "lint": "eslint .",
    "lint:fix": "eslint . --fix",
    "typecheck": "tsc -p ./jsconfig.json",
    "preview": "vite preview"
  }
}
EOF

cat > "$ROOT_DIR/postcss.config.js" <<'EOF'
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
EOF

cat > "$ROOT_DIR/README.md" <<'EOF'
# Base44 App
EOF

cat > "$ROOT_DIR/tailwind.config.js" <<'EOF'
/** @type {import('tailwindcss').Config} */
module.exports = {
    darkMode: ["class"],
    content: ["./index.html", "./src/**/*.{ts,tsx,js,jsx}"],
  theme: {
  	extend: {}
  },
  plugins: [require("tailwindcss-animate")],
}
EOF

cat > "$ROOT_DIR/components/LanguageCard.tsx" <<'EOF'
import React from 'react';
import { Language } from '../types';

interface LanguageCardProps {
  language: Language;
  onSelect: (lang: Language) => void;
}

export const LanguageCard: React.FC<LanguageCardProps> = ({ language, onSelect }) => {
  return (
    <div className="relative h-80 rounded-2xl overflow-hidden group cursor-pointer border border-gray-800 transition-transform hover:scale-[1.02]" onClick={() => onSelect(language)}>
      <img src={language.image} alt={language.name} className="absolute inset-0 w-full h-full object-cover transition-transform duration-500 group-hover:scale-110" />
      <div className="absolute inset-0 bg-gradient-to-b from-black/20 via-black/40 to-black/90"></div>
      <div className="absolute top-4 right-4 bg-white/20 backdrop-blur-md px-2 py-1 rounded text-xs font-bold text-white uppercase">
        {language.id.toUpperCase()}
      </div>
      <div className="absolute bottom-0 left-0 right-0 p-6 flex flex-col gap-1">
        <h3 className="text-2xl font-bold text-white">{language.name}</h3>
        <p className="text-gray-300 text-sm mb-4">{language.description}</p>
        <div className="flex items-center justify-between mt-2">
          <span className="text-xs text-gray-400">{language.courseCount} cursos</span>
          <button className={`px-4 py-2 rounded-full text-white text-xs font-bold ${language.buttonColor}`}>Ver Aulas</button>
        </div>
      </div>
    </div>
  );
};
EOF

cat > "$ROOT_DIR/components/LiveTutor.tsx" <<'EOF'
/* Placeholder LiveTutor (original file had elided sections) */
import React from 'react';

interface LiveTutorProps {
  language: any;
  onExit: () => void;
}

export const LiveTutor: React.FC<LiveTutorProps> = ({ language, onExit }) => {
  return <div />;
};
EOF

cat > "$ROOT_DIR/components/Sidebar.tsx" <<'EOF'
import React from 'react';
import { MENU_ITEMS, Icons } from '../constants';

export const Sidebar: React.FC = () => {
  return (
    <div className="w-64 h-screen bg-orbit-sidebar flex flex-col border-r border-gray-900 sticky top-0">
      <div className="p-6">
        <div className="flex items-center gap-3 text-white mb-8">
            <div className="w-8 h-8 bg-orbit-primary rounded-lg flex items-center justify-center">
                <Icons.Sparkles />
            </div>
            <div className="flex flex-col">
                <span className="font-bold text-lg">Orbit AI</span>
                <span className="text-[10px] text-gray-400 uppercase">Language</span>
            </div>
        </div>
      </div>
    </div>
  );
};
EOF

cat > "$ROOT_DIR/services/audioUtils.ts" <<'EOF'
export function base64ToUint8Array(base64: string): Uint8Array {
  const binaryString = atob(base64);
  const len = binaryString.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) bytes[i] = binaryString.charCodeAt(i);
  return bytes;
}

export async function decodeAudioData(data: Uint8Array, ctx: AudioContext, sampleRate = 24000, numChannels = 1): Promise<AudioBuffer> {
  const dataInt16 = new Int16Array(data.buffer);
  const frameCount = dataInt16.length / numChannels;
  const buffer = ctx.createBuffer(numChannels, frameCount, sampleRate);
  for (let c = 0; c < numChannels; c++) {
    const channelData = buffer.getChannelData(c);
    for (let i = 0; i < frameCount; i++) channelData[i] = dataInt16[i * numChannels + c] / 32768.0;
  }
  return buffer;
}

export function float32ToB64PCM(data: Float32Array): string {
  const l = data.length;
  const int16 = new Int16Array(l);
  for (let i = 0; i < l; i++) {
    let s = Math.max(-1, Math.min(1, data[i]));
    int16[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
  }
  let binary = '';
  const bytes = new Uint8Array(int16.buffer);
  for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}
EOF

cat > "$ROOT_DIR/App.tsx" <<'EOF'
import React, { useState, useEffect } from 'react';
import { LanguageCard } from './components/LanguageCard';
import { LiveTutor } from './components/LiveTutor';
import { LANGUAGES } from './constants';
import { Language } from './types';
import { Icons } from './constants';

function App() {
  const [selectedLanguage, setSelectedLanguage] = useState<Language | null>(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const langId = params.get('lang');
    if (langId) {
      const foundLang = LANGUAGES.find(l => l.id === langId);
      if (foundLang) setSelectedLanguage(foundLang);
    }
  }, []);

  const handleStartSession = (language: Language) => {
    setSelectedLanguage(language);
    const newUrl = `${window.location.pathname}?lang=${language.id}`;
    window.history.pushState({ path: newUrl }, '', newUrl);
  };

  const handleExit = () => {
    setSelectedLanguage(null);
    window.history.pushState({}, '', window.location.pathname);
  };

  if (selectedLanguage) {
    return <div className="w-screen h-screen bg-black overflow-hidden"><LiveTutor language={selectedLanguage} onExit={handleExit} /></div>;
  }

  return (
    <div className="min-h-screen bg-[#050505] text-white flex flex-col items-center justify-center p-8 font-sans">
      <div className="max-w-5xl w-full space-y-12">
        <h1 className="text-4xl font-bold">Orbit AI Server</h1>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          {LANGUAGES.map(lang => <LanguageCard key={lang.id} language={lang} onSelect={handleStartSession} />)}
        </div>
      </div>
    </div>
  );
}

export default App;
EOF

cat > "$ROOT_DIR/constants.tsx" <<'EOF'
import React from 'react';
import { Language, NavItem } from './types';

export const Icons = {
  Sparkles: () => <svg width="20" height="20" viewBox="0 0 24 24"><path/></svg>,
};

export const LANGUAGES: Language[] = [
  { id: 'it', name: 'Italiano', nativeName: 'Italiano', description: 'Arte & Tradição', courseCount: 3, image: 'https://picsum.photos/id/1040/400/500', color: 'bg-teal-600', buttonColor: 'bg-emerald-500', voiceName: 'Kore' },
  { id: 'es', name: 'Espanhol', nativeName: 'Español', description: 'Cultura & Conexão', courseCount: 0, image: 'https://picsum.photos/id/1015/400/500', color: 'bg-orange-600', buttonColor: 'bg-orange-500', voiceName: 'Puck' },
  { id: 'us', name: 'Inglês', nativeName: 'English', description: 'Negócios & Viagens', courseCount: 0, image: 'https://picsum.photos/id/1068/400/500', color: 'bg-blue-600', buttonColor: 'bg-indigo-500', voiceName: 'Fenrir' },
  { id: 'br', name: 'Português', nativeName: 'Português', description: 'Diversidade & Ritmo', courseCount: 0, image: 'https://picsum.photos/id/1016/400/500', color: 'bg-green-600', buttonColor: 'bg-green-500', voiceName: 'Zephyr' },
];

export const MENU_ITEMS: NavItem[] = [
  { id: 'dashboard', label: 'Dashboard', icon: <Icons.Sparkles />, isActive: true },
];
EOF

cat > "$ROOT_DIR/index.tsx" <<'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';

const rootElement = document.getElementById('root');
if (!rootElement) throw new Error("No root element");
ReactDOM.createRoot(rootElement).render(<App />);
EOF

cat > "$ROOT_DIR/metadata.json" <<'EOF'
{
  "name": "Orbit Language AI",
  "description": "An AI-powered language learning assistant offering real-time conversation practice and speech correction.",
  "requestFramePermissions": ["microphone"]
}
EOF

cat > "$ROOT_DIR/README.orbit-AI.md" <<'EOF'
# Orbit Language AI

Run locally:
1. npm install
2. npm run dev
EOF

cat > "$ROOT_DIR/package.orbit-AI.json" <<'EOF'
{
  "name": "orbit-language-ai",
  "private": true,
  "version": "0.0.0"
}
EOF

cat > "$ROOT_DIR/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "jsx": "react-jsx"
  }
}
EOF

cat > "$ROOT_DIR/types.ts" <<'EOF'
export interface Language {
  id: string;
  name: string;
  nativeName: string;
  description: string;
  courseCount: number;
  image: string;
  color: string;
  buttonColor: string;
  voiceName: string;
}
EOF

cat > "$ROOT_DIR/vite.config.ts" <<'EOF'
import path from 'path';
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, '.', '');
    return {
      server: { port: 3000, host: '0.0.0.0' },
      plugins: [react()],
      resolve: { alias: { '@': path.resolve(__dirname, '.') } }
    };
});
EOF

# Create zip
zip -r "${ROOT_DIR}.zip" "$ROOT_DIR" > /dev/null
echo "Created ${ROOT_DIR}.zip in $(pwd)"
EOF