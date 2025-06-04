declare module 'react-native/Libraries/Image/resolveAssetSource' {
    const resolveAssetSource: any;
    export default resolveAssetSource;
  }
  
  declare module '@react-native/assets-registry/registry' {
    export function getAssetByID(id: number): any;
  }
  