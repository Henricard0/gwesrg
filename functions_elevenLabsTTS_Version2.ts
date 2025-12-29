import { createClientFromRequest } from 'npm:@base44/sdk@0.8.4';

// Voice IDs por idioma (configure conforme suas vozes do ElevenLabs)
const VOICE_MAP = {
    'pt': 'pNInz6obpgDQGcFmaJgB', // Adam (multilingual) - Português
    'en': 'EXAVITQu4vr4xnSDxMaL', // Sarah - Inglês
    'it': 'XB0fDUnXU5powFXDhCwa', // Charlotte - Italiano
    'es': 'onwK4e9ZLuTAKqWW03F9', // Daniel - Espanhol
    'default': 'pNInz6obpgDQGcFmaJgB' // Fallback
};

function detectLanguage(text) {
    const lowerText = text.toLowerCase();
    
    // Português
    if (/\b(você|está|são|não|sim|muito|mais|como|que|para|onde)\b/.test(lowerText)) {
        return 'pt';
    }
    // Inglês
    if (/\b(you|are|the|is|and|what|how|where|when|why)\b/.test(lowerText)) {
        return 'en';
    }
    // Italiano
    if (/\b(sei|come|dove|quando|perché|cosa|sono|molto)\b/.test(lowerText)) {
        return 'it';
    }
    // Espanhol
    if (/\b(eres|cómo|dónde|cuándo|por qué|qué|son|muy)\b/.test(lowerText)) {
        return 'es';
    }
    
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

        // Detecta idioma ou usa o fornecido
        const detectedLang = language || detectLanguage(text);
        const voiceId = VOICE_MAP[detectedLang] || VOICE_MAP['default'];
        
        console.log(`Text: "${text.substring(0, 50)}..." | Detected language: ${detectedLang} | Voice: ${voiceId}`);
        
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
                    voice_settings: {
                        stability: 0.5,
                        similarity_boost: 0.75,
                        style: 0.0,
                        use_speaker_boost: true
                    },
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
            headers: {
                'Content-Type': 'audio/mpeg',
                'Content-Length': audioBuffer.byteLength.toString(),
            },
        });
        
    } catch (error) {
        console.error('Error in elevenLabsTTS:', error);
        return Response.json({ error: error.message }, { status: 500 });
    }
});